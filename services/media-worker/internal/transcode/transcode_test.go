package transcode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// requireFFmpeg skips the test when the host has no ffmpeg or ffprobe in PATH.
func requireFFmpeg(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not in PATH (install ffmpeg to run this test): %v", tool, err)
		}
	}
}

// generate writes a synthetic clip from ffmpeg's lavfi sources into a temporary directory.
func generate(t *testing.T, name string, args ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	full := append([]string{"-hide_banner", "-nostdin", "-loglevel", "error", "-y"}, args...)
	full = append(full, path)
	out, err := exec.CommandContext(t.Context(), "ffmpeg", full...).CombinedOutput() //nolint:gosec // test fixture command
	if err != nil {
		t.Fatalf("generate %s: %v\n%s", name, err, out)
	}
	return path
}

// clip returns lavfi inputs for a test pattern of the given size and length, with a sine tone
// when audio is set.
func clip(size string, seconds int, audio bool) []string {
	args := []string{"-f", "lavfi", "-i", fmt.Sprintf("testsrc2=size=%s:rate=30:duration=%d", size, seconds)}
	if audio {
		args = append(args, "-f", "lavfi", "-i", fmt.Sprintf("sine=frequency=440:duration=%d", seconds))
	}
	return args
}

func h264AAC(size string, seconds int) []string {
	return append(clip(size, seconds, true), "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest")
}

func runOK(t *testing.T, input string) (Result, string) {
	t.Helper()
	out := filepath.Join(t.TempDir(), "out")
	res, err := Run(context.Background(), input, out)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return res, out
}

// probeStreams lists the codec types of a file's streams, as ffprobe reads it back.
func probeStreams(t *testing.T, path string) string {
	t.Helper()
	out, err := exec.CommandContext(t.Context(), "ffprobe", "-v", "error", "-show_entries", "stream=codec_type", //nolint:gosec // path of a test output
		"-of", "json", path).Output()
	if err != nil {
		t.Fatalf("ffprobe %s: %v", path, err)
	}
	var p probeResult
	if err := json.Unmarshal(out, &p); err != nil {
		t.Fatal(err)
	}
	types := make([]string, len(p.Streams))
	for i, st := range p.Streams {
		types[i] = st.CodecType
	}
	return strings.Join(types, ",")
}

func checkRenditions(t *testing.T, got []Rendition, want []Rendition) {
	t.Helper()
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("renditions = %v, want %v", got, want)
	}
}

func TestRunLandscape1080pGivesThreeRenditions(t *testing.T) {
	requireFFmpeg(t)
	input := generate(t, "in.mp4", h264AAC("1920x1080", 6)...)

	start := time.Now()
	res, out := runOK(t, input)
	t.Logf("transcode of 1080p 6 s took %v", time.Since(start).Round(time.Millisecond))

	checkRenditions(t, res.Renditions, []Rendition{
		{"360p", 640, 360, 800_000},
		{"720p", 1280, 720, 2_500_000},
		{"1080p", 1920, 1080, 5_000_000},
	})
	if d := res.Duration; d < 5900*time.Millisecond || d > 6100*time.Millisecond {
		t.Errorf("duration = %v, want about 6s", d)
	}

	master := readFile(t, filepath.Join(out, MasterPlaylist))
	if n := strings.Count(string(master), "#EXT-X-STREAM-INF:"); n != 3 {
		t.Errorf("master lists %d variants, want 3:\n%s", n, master)
	}
	for _, r := range []string{"360p", "720p", "1080p"} {
		if !strings.Contains(string(master), r+"/"+playlistName) {
			t.Errorf("master does not list %s/%s", r, playlistName)
		}
	}

	// Upload order: every segment before any playlist, master last, content types set.
	files := res.Files
	if len(files) == 0 || files[len(files)-1].Path != MasterPlaylist {
		t.Fatalf("files = %v, want %s last", files, MasterPlaylist)
	}
	seenPlaylist := false
	segments := 0
	for _, f := range files {
		switch {
		case strings.HasSuffix(f.Path, ".ts"):
			segments++
			if seenPlaylist {
				t.Errorf("segment %s comes after a playlist", f.Path)
			}
			if f.ContentType != "video/mp2t" {
				t.Errorf("%s content type = %q", f.Path, f.ContentType)
			}
			// Each segment is playable on its own: ffprobe finds H.264 video and AAC audio.
			if got := probeStreams(t, filepath.Join(out, f.Path)); got != "video,audio" {
				t.Errorf("%s streams = %q, want video,audio", f.Path, got)
			}
		case strings.HasSuffix(f.Path, ".m3u8"):
			seenPlaylist = true
			if f.ContentType != "application/vnd.apple.mpegurl" {
				t.Errorf("%s content type = %q", f.Path, f.ContentType)
			}
		case f.Path == Thumbnail:
			if f.ContentType != "image/jpeg" {
				t.Errorf("%s content type = %q", f.Path, f.ContentType)
			}
		default:
			t.Errorf("unexpected file %s", f.Path)
		}
	}
	// 6 s at 4 s segments: two segments in each of three renditions.
	if segments != 6 {
		t.Errorf("%d segments, want 6", segments)
	}
	if got := probeStreams(t, filepath.Join(out, Thumbnail)); got != "video" {
		t.Errorf("thumbnail streams = %q, want one image", got)
	}
	// The poster stops at 720 px on its short side, below the 1080p rendition.
	if got := thumbnailSize(t, out); got != "1280,720" {
		t.Errorf("thumbnail size = %q, want 1280,720", got)
	}
}

func TestRunLadderFollowsShortSide(t *testing.T) {
	requireFFmpeg(t)
	tests := []struct {
		name string
		size string
		want []Rendition
	}{
		{"portrait 720x1280", "720x1280", []Rendition{
			{"360p", 360, 640, 800_000},
			{"720p", 720, 1280, 2_500_000},
		}},
		{"small 320x240 keeps its size", "320x240", []Rendition{
			{"source", 320, 240, 800_000},
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			input := generate(t, "in.mp4", h264AAC(tt.size, 2)...)
			res, _ := runOK(t, input)
			checkRenditions(t, res.Renditions, tt.want)
		})
	}
}

// TestRunRotatedPhoneVideo covers the usual phone upload, since most videos are portrait:
// landscape frames stored with a 90° display matrix. Autorotation must make every
// output portrait.
func TestRunRotatedPhoneVideo(t *testing.T) {
	requireFFmpeg(t)
	base := generate(t, "base.mp4", h264AAC("640x360", 2)...)
	input := generate(t, "rot.mp4", "-display_rotation:v:0", "90", "-i", base, "-c", "copy")
	res, out := runOK(t, input)
	checkRenditions(t, res.Renditions, []Rendition{{"360p", 360, 640, 800_000}})
	master := readFile(t, filepath.Join(out, MasterPlaylist))
	if !strings.Contains(string(master), "RESOLUTION=360x640") {
		t.Errorf("master does not declare RESOLUTION=360x640:\n%s", master)
	}
	if got := thumbnailSize(t, out); got != "360,640" {
		t.Errorf("thumbnail size = %q, want 360,640", got)
	}
}

// thumbnailSize returns "width,height" of the thumbnail in out.
func thumbnailSize(t *testing.T, out string) string {
	t.Helper()
	thumb, err := exec.CommandContext(t.Context(), "ffprobe", "-v", "error", "-show_entries", "stream=width,height", //nolint:gosec // path of a test output
		"-of", "csv=p=0", filepath.Join(out, Thumbnail)).Output()
	if err != nil {
		t.Fatalf("ffprobe thumbnail: %v", err)
	}
	return strings.TrimSpace(string(thumb))
}

func TestRunWebMVP9Opus(t *testing.T) {
	requireFFmpeg(t)
	input := generate(t, "in.webm", append(clip("320x240", 2, true),
		"-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus", "-shortest")...)
	res, out := runOK(t, input)
	checkRenditions(t, res.Renditions, []Rendition{{"source", 320, 240, 800_000}})
	if got := probeStreams(t, filepath.Join(out, "source", "seg_000.ts")); got != "video,audio" {
		t.Errorf("segment streams = %q, want video,audio", got)
	}
}

func TestRunWithoutAudio(t *testing.T) {
	requireFFmpeg(t)
	input := generate(t, "in.mp4", append(clip("640x360", 2, false), "-c:v", "libx264", "-preset", "ultrafast")...)
	res, out := runOK(t, input)
	checkRenditions(t, res.Renditions, []Rendition{{"360p", 640, 360, 800_000}})
	if got := probeStreams(t, filepath.Join(out, "360p", "seg_000.ts")); got != "video" {
		t.Errorf("segment streams = %q, want video only", got)
	}
	master := readFile(t, filepath.Join(out, MasterPlaylist))
	if strings.Contains(string(master), "mp4a") {
		t.Errorf("master declares an audio codec:\n%s", master)
	}
}

func runErr(t *testing.T, input string, lim limits) (string, error) {
	t.Helper()
	out := filepath.Join(t.TempDir(), "out")
	_, err := run(context.Background(), input, out, lim)
	if err == nil {
		t.Fatal("run succeeded, want an error")
	}
	return out, err
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path) //nolint:gosec // a file this test generated
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func writeFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestRunRejectsNonVideo(t *testing.T) {
	requireFFmpeg(t)
	dir := t.TempDir()
	for name, content := range map[string]string{
		"text.mp4":  "this is plain text, not a video\n",
		"empty.mp4": "",
	} {
		t.Run(name, func(t *testing.T) {
			out, err := runErr(t, writeFile(t, dir, name, content), defaultLimits)
			if !errors.Is(err, ErrInvalidInput) {
				t.Errorf("err = %v, want ErrInvalidInput", err)
			}
			if strings.Contains(err.Error(), dir) {
				t.Errorf("error %q contains the job directory path", err)
			}
			if _, statErr := os.Stat(out); !os.IsNotExist(statErr) {
				t.Errorf("output directory exists after a rejected probe: %v", statErr)
			}
		})
	}
}

// TestRunRejectsReferencingFormats feeds playlist and concat files that point at other local
// files (FF-2). The referenced file is a FIFO with no writer, named relative to the playlist (the
// concat demuxer refuses absolute names on its own): without the format whitelist ffprobe opens
// it and blocks until the probe timeout, failing with a deadline error instead of
// ErrInvalidInput.
func TestRunRejectsReferencingFormats(t *testing.T) {
	requireFFmpeg(t)
	dir := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(dir, "other.mp4"), 0o600); err != nil {
		t.Fatal(err)
	}
	hls := "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nother.mp4\n#EXTINF:4,\n/etc/passwd\n#EXT-X-ENDLIST\n"
	concat := "ffconcat version 1.0\nfile 'other.mp4'\n"
	tests := map[string]string{
		"hls.m3u8":          hls,
		"hls-renamed.mp4":   hls,
		"list.ffconcat":     concat,
		"concat-plain.webm": concat,
	}
	lim := limits{probeTimeout: 10 * time.Second, ffmpegTimeout: 10 * time.Second}
	for name, content := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := runErr(t, writeFile(t, dir, name, content), lim)
			if !errors.Is(err, ErrInvalidInput) {
				t.Errorf("err = %v, want ErrInvalidInput", err)
			}
		})
	}
}

func TestRunRejectsCodecOutsideWhitelist(t *testing.T) {
	requireFFmpeg(t)
	tests := map[string][]string{
		"mpeg4.mp4": append(clip("320x240", 1, false), "-c:v", "mpeg4"),
		"mjpeg.mov": append(clip("320x240", 1, false), "-c:v", "mjpeg"),
	}
	for name, args := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := runErr(t, generate(t, name, args...), defaultLimits)
			if !errors.Is(err, ErrInvalidInput) {
				t.Errorf("err = %v, want ErrInvalidInput", err)
			}
			if !strings.Contains(err.Error(), "not on whitelist") {
				t.Errorf("err = %v, want the whitelist refusal as detail", err)
			}
		})
	}
}

func TestRunDurationExceeded(t *testing.T) {
	requireFFmpeg(t)
	input := generate(t, "long.mp4", "-f", "lavfi", "-i", "color=c=black:size=64x64:rate=1:duration=182",
		"-c:v", "libx264", "-preset", "ultrafast")
	out, err := runErr(t, input, defaultLimits)
	if !errors.Is(err, ErrDurationExceeded) {
		t.Errorf("err = %v, want ErrDurationExceeded", err)
	}
	if errors.Is(err, ErrInvalidInput) {
		t.Errorf("err = %v is also ErrInvalidInput", err)
	}
	if _, statErr := os.Stat(out); !os.IsNotExist(statErr) {
		t.Errorf("ffmpeg ran on a file over the limit: output directory %v", statErr)
	}
}

func TestRunStripsMetadata(t *testing.T) {
	requireFFmpeg(t)
	const title, location = "Secret Holiday Title", "+48.8577+002.2950/"
	input := generate(t, "in.mov", append(h264AAC("640x360", 2),
		"-metadata", "title="+title, "-metadata", "location="+location,
		"-metadata:s:v:0", "handler_name="+title)...)
	src := readFile(t, input)
	if !bytes.Contains(src, []byte(title)) || !bytes.Contains(src, []byte(location)) {
		t.Fatal("generated input does not carry the metadata under test")
	}

	res, out := runOK(t, input)
	for _, f := range res.Files {
		data := readFile(t, filepath.Join(out, f.Path))
		for _, v := range []string{title, location} {
			if bytes.Contains(data, []byte(v)) {
				t.Errorf("%s contains input metadata %q", f.Path, v)
			}
		}
	}
}

func TestRunTimeoutKillsFFmpeg(t *testing.T) {
	requireFFmpeg(t)
	input := generate(t, "in.mp4", h264AAC("1920x1080", 6)...)
	lim := limits{probeTimeout: 30 * time.Second, ffmpegTimeout: 300 * time.Millisecond}

	out, err := runErr(t, input, lim)
	if errors.Is(err, ErrInvalidInput) || errors.Is(err, ErrDurationExceeded) {
		t.Errorf("err = %v, want a transient error", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("err = %v, want it to wrap context.DeadlineExceeded", err)
	}
	// The output directory appears in the ffmpeg command line, so it names this run's process.
	if ps, err := exec.CommandContext(t.Context(), "pgrep", "-fl", out).Output(); err == nil { //nolint:gosec // a temporary directory path
		t.Errorf("ffmpeg still running after Run returned:\n%s", ps)
	}
}

func TestCheckLimits(t *testing.T) {
	video := probeStream{CodecType: "video", CodecName: "h264", Width: 1920, Height: 1080, AvgFrameRate: "30/1"}
	audio := probeStream{CodecType: "audio", CodecName: "aac"}
	mp4 := func(duration string, streams ...probeStream) probeResult {
		p := probeResult{Streams: streams}
		p.Format.FormatName = "mov,mp4,m4a,3gp,3g2,mj2"
		p.Format.Duration = duration
		return p
	}
	with := func(f func(*probeStream)) probeStream {
		s := video
		f(&s)
		return s
	}
	tests := []struct {
		name string
		p    probeResult
		want error
	}{
		{"valid", mp4("60", video, audio), nil},
		{"phone data track", mp4("60", video, audio, probeStream{CodecType: "data"}), nil},
		{"181 s within slack", mp4("181.0", video), nil},
		{"no duration declared", mp4("", video), nil},
		{"over 181 s", mp4("181.5", video), ErrDurationExceeded},
		{"stream duration over limit", mp4("", with(func(s *probeStream) { s.Duration = "300" })), ErrDurationExceeded},
		{"no video", mp4("10", audio), ErrInvalidInput},
		{"nine streams", mp4("10", video, audio, audio, audio, audio, audio, audio, audio, audio), ErrInvalidInput},
		{"long side over 4096", mp4("10", with(func(s *probeStream) { s.Width = 4097 })), ErrInvalidInput},
		{"4096 is allowed", mp4("10", with(func(s *probeStream) { s.Height = 4096 })), nil},
		{"fps over 120", mp4("10", with(func(s *probeStream) { s.AvgFrameRate = "240/1" })), ErrInvalidInput},
		{"fps from r_frame_rate", mp4("10", with(func(s *probeStream) { s.AvgFrameRate, s.RFrameRate = "0/0", "121/1" })), ErrInvalidInput},
		{"subtitle stream", mp4("10", video, probeStream{CodecType: "subtitle", CodecName: "mov_text"}), ErrInvalidInput},
		{"video codec", mp4("10", with(func(s *probeStream) { s.CodecName = "mpeg4" })), ErrInvalidInput},
		{"audio codec", mp4("10", video, probeStream{CodecType: "audio", CodecName: "pcm_s16le"}), ErrInvalidInput},
		{"container", func() probeResult { p := mp4("10", video); p.Format.FormatName = "avi"; return p }(), ErrInvalidInput},
		{"invalid beats duration", mp4("500", video, probeStream{CodecType: "subtitle"}), ErrInvalidInput},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.p.check()
			if tt.want == nil && err != nil {
				t.Errorf("check() = %v, want nil", err)
			}
			if tt.want != nil && !errors.Is(err, tt.want) {
				t.Errorf("check() = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestLastLineStripsJobPaths(t *testing.T) {
	b := &tailBuffer{max: 100}
	_, _ = fmt.Fprintf(b, "%s\n", strings.Repeat("x", 100))
	_, _ = fmt.Fprint(b, "file:/work/abc/source.mp4: Invalid data found when processing input\n")
	got := b.lastLine([]string{"/work/abc"})
	if want := "source.mp4: Invalid data found when processing input"; got != want {
		t.Errorf("lastLine = %q, want %q", got, want)
	}

	long := &tailBuffer{max: 4096}
	_, _ = fmt.Fprint(long, strings.Repeat("y", 2000))
	if got := long.lastLine(nil); len(got) != maxDetail {
		t.Errorf("len(lastLine) = %d, want %d", len(got), maxDetail)
	}
}
