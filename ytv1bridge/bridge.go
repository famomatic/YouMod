// YouMod's bridge to ytv1 (github.com/famomatic/ytv1), the Go YouTube extractor.
//
// CI copies this directory into a ytv1 checkout (as mobile/ytv1ios) and builds it
// with -buildmode=c-archive for ios/arm64; the archive is then linked into
// YTV1.framework, which YouMod dlopens the first time the "ytv1" download method is
// used. Living inside the ytv1 module tree lets it use ytv1's internal packages.
//
// C API (see ../Files/YTV1.h):
//   ytv1_download   fetch one format (itag) of a video into a directory
//   ytv1_cancel     cancel a running download
//   ytv1_version    ytv1 commit the framework was built from
package main

/*
#include <stdint.h>
#include <stdlib.h>
typedef void (*ytv1_progress_fn)(void *ctx, int64_t downloaded, int64_t total);
typedef void (*ytv1_done_fn)(void *ctx, const char *path, int itag, const char *mime, const char *error);
static inline void ytv1_call_progress(ytv1_progress_fn f, void *ctx, int64_t d, int64_t t) { if (f) f(ctx, d, t); }
static inline void ytv1_call_done(ytv1_done_fn f, void *ctx, const char *p, int itag, const char *m, const char *e) { if (f) f(ctx, p, itag, m, e); }
*/
import "C"

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/famomatic/ytv1/client"
)

// Filled in by the build (-ldflags -X main.ytv1Commit=...).
var ytv1Commit = "unknown"

type job struct {
	cancel   context.CancelFunc
	progress C.ytv1_progress_fn
	ctx      unsafe.Pointer
	key      string // videoID|itag being downloaded, for progress routing
}

var (
	mu      sync.Mutex
	jobs    = map[int64]*job{}
	nextID  int64
	shared  *client.Client
	initOne sync.Once
)

func progressKey(videoID string, itag int) string { return fmt.Sprintf("%s|%d", videoID, itag) }

func ytClient() *client.Client {
	initOne.Do(func() {
		tr := http.DefaultTransport.(*http.Transport).Clone()
		tr.DialContext = (&net.Dialer{Timeout: 20 * time.Second, KeepAlive: 30 * time.Second}).DialContext
		tr.ResponseHeaderTimeout = 30 * time.Second
		tr.TLSHandshakeTimeout = 15 * time.Second
		shared = client.New(client.Config{
			HTTPClient: &http.Client{Transport: tr},
			// No whole-operation timeout: a download can legitimately take long.
			// Stalls are bounded by the transport timeouts above and by cancel.
			RequestTimeout: 0,
			DownloadTransport: client.DownloadTransportConfig{
				MaxRetries:     5,
				InitialBackoff: time.Second,
				MaxConcurrency: 4,
			},
			MetadataTransport: client.MetadataTransportConfig{
				MaxRetries:     3,
				InitialBackoff: time.Second,
			},
			OnDownloadProgress: func(ev client.DownloadProgressEvent) {
				key := progressKey(ev.VideoID, ev.Itag)
				mu.Lock()
				var targets []*job
				for _, j := range jobs {
					if j.key == key {
						targets = append(targets, j)
					}
				}
				mu.Unlock()
				for _, j := range targets {
					C.ytv1_call_progress(j.progress, j.ctx, C.int64_t(ev.Downloaded), C.int64_t(ev.Total))
				}
			},
		})
	})
	return shared
}

func isAudioOnly(f client.FormatInfo) bool { return f.HasAudio && !f.HasVideo }
func isVideoOnly(f client.FormatInfo) bool { return f.HasVideo && !f.HasAudio }

func container(mime string) string {
	m := strings.ToLower(mime)
	switch {
	case strings.Contains(m, "webm"):
		return "webm"
	case strings.Contains(m, "audio/mp4"):
		return "m4a"
	default:
		return "mp4"
	}
}

func codecFamily(mime string) string {
	m := strings.ToLower(mime)
	for _, c := range []string{"av01", "vp9", "vp09", "avc1", "opus", "mp4a"} {
		if strings.Contains(m, c) {
			if c == "vp09" {
				return "vp9"
			}
			return c
		}
	}
	return ""
}

func usable(f client.FormatInfo) bool {
	return !f.IsDRM && !f.IsDamaged && !f.Incomplete
}

// pickFormat returns the requested itag when ytv1 found it, otherwise the closest
// format of the same kind: for video the same height (then lower), same fps and
// codec family first; for audio the same codec family, highest bitrate.
func pickFormat(formats []client.FormatInfo, itag int, wantAudio bool, height, fps int, mime string) (client.FormatInfo, bool) {
	// Plain progressive HTTPS formats first; HLS/DASH variants of the same itag only
	// when nothing else exists.
	https := formats[:0:0]
	for _, f := range formats {
		if usable(f) && strings.EqualFold(f.Protocol, "https") {
			https = append(https, f)
		}
	}
	if len(https) == 0 {
		for _, f := range formats {
			if usable(f) {
				https = append(https, f)
			}
		}
	}
	formats = https
	for _, f := range formats {
		if f.Itag == itag {
			return f, true
		}
	}
	family := codecFamily(mime)
	var cands []client.FormatInfo
	for _, f := range formats {
		if wantAudio && isAudioOnly(f) {
			cands = append(cands, f)
		} else if !wantAudio && isVideoOnly(f) && (height <= 0 || f.Height <= height) {
			cands = append(cands, f)
		}
	}
	if len(cands) == 0 {
		return client.FormatInfo{}, false
	}
	score := func(f client.FormatInfo) []int {
		sameFamily := 0
		if family != "" && codecFamily(f.MimeType) == family {
			sameFamily = 1
		}
		if wantAudio {
			return []int{sameFamily, f.Bitrate}
		}
		sameFPS := 0
		if fps <= 0 || f.FPS == fps {
			sameFPS = 1
		}
		return []int{f.Height, sameFPS, sameFamily, f.FPS, f.Bitrate}
	}
	sort.SliceStable(cands, func(i, j int) bool {
		a, b := score(cands[i]), score(cands[j])
		for k := range a {
			if a[k] != b[k] {
				return a[k] > b[k]
			}
		}
		return false
	})
	return cands[0], true
}

//export ytv1_download
func ytv1_download(cVideoID *C.char, cItag C.int, cAudio C.int, cHeight C.int, cFPS C.int, cMime *C.char,
	cDir *C.char, cBase *C.char, progress C.ytv1_progress_fn, done C.ytv1_done_fn, cbctx unsafe.Pointer) C.int64_t {
	videoID := C.GoString(cVideoID)
	itag := int(cItag)
	wantAudio := cAudio != 0
	height, fps := int(cHeight), int(cFPS)
	mime := C.GoString(cMime)
	dir := C.GoString(cDir)
	base := C.GoString(cBase)

	ctx, cancel := context.WithCancel(context.Background())
	j := &job{cancel: cancel, progress: progress, ctx: cbctx}
	mu.Lock()
	nextID++
	id := nextID
	jobs[id] = j
	mu.Unlock()

	go func() {
		finish := func(path string, gotItag int, gotMime string, err error) {
			cancelled := ctx.Err() != nil
			mu.Lock()
			delete(jobs, id)
			mu.Unlock()
			cancel()
			var cPath, cMimeOut, cErr *C.char
			if err == nil {
				cPath = C.CString(path)
				cMimeOut = C.CString(gotMime)
			} else {
				msg := err.Error()
				if cancelled {
					msg = "cancelled"
				}
				cErr = C.CString(msg)
			}
			C.ytv1_call_done(done, cbctx, cPath, C.int(gotItag), cMimeOut, cErr)
			if cPath != nil {
				C.free(unsafe.Pointer(cPath))
			}
			if cMimeOut != nil {
				C.free(unsafe.Pointer(cMimeOut))
			}
			if cErr != nil {
				C.free(unsafe.Pointer(cErr))
			}
		}
		defer func() {
			if r := recover(); r != nil {
				finish("", 0, "", fmt.Errorf("ytv1 panic: %v", r))
			}
		}()

		c := ytClient()
		info, err := c.GetVideo(ctx, videoID)
		if err != nil {
			finish("", 0, "", err)
			return
		}
		f, ok := pickFormat(info.Formats, itag, wantAudio, height, fps, mime)
		if !ok {
			finish("", 0, "", fmt.Errorf("no matching format for itag %d", itag))
			return
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			finish("", 0, "", err)
			return
		}
		out := filepath.Join(dir, base+"."+container(f.MimeType))
		_ = os.Remove(out)
		mu.Lock()
		j.key = progressKey(videoID, f.Itag)
		mu.Unlock()
		res, err := c.Download(ctx, videoID, client.DownloadOptions{
			Itag:               f.Itag,
			OutputPath:         out,
			OutputPathResolved: true,
			NoEmbedMetadata:    true,
		})
		if err != nil {
			finish("", 0, "", err)
			return
		}
		path := out
		if res != nil && res.OutputPath != "" {
			path = res.OutputPath
		}
		finish(path, f.Itag, f.MimeType, nil)
	}()
	return C.int64_t(id)
}

//export ytv1_cancel
func ytv1_cancel(id C.int64_t) {
	mu.Lock()
	j := jobs[int64(id)]
	mu.Unlock()
	if j != nil {
		j.cancel()
	}
}

//export ytv1_version
func ytv1_version() *C.char { return C.CString(ytv1Commit) }

//export ytv1_free
func ytv1_free(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
