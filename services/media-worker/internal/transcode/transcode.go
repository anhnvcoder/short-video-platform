// Package transcode turns one local video file into HLS (up to three renditions) and a
// thumbnail with ffprobe and ffmpeg found in PATH, under the limits of docs/threat-model.md
// §4.3 (FF-1 to FF-3, FF-7). It knows nothing about Kafka or storage.
//
// Errors are ErrInvalidInput or ErrDurationExceeded (wrapped with a detail) when the probe shows
// the file is the problem. Other errors are returned as they are, and the caller classifies them:
// a timeout wraps context.DeadlineExceeded, and a tool that exited non-zero or was killed by a
// signal surfaces as *exec.ExitError. media-worker treats all three as permanent INVALID_INPUT,
// because retrying would run a crafted file again (worker.permanentReason).
package transcode

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"

	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

var (
	// ErrInvalidInput means the file is unreadable, uses a container or codec outside the
	// whitelist, or breaks an input limit other than duration (reason INVALID_INPUT).
	ErrInvalidInput = errors.New("transcode: invalid input")
	// ErrDurationExceeded means the file declares a length over the limit (reason
	// DURATION_EXCEEDED).
	ErrDurationExceeded = errors.New("transcode: duration exceeded")
)

// Output layout and content types. Run writes master.m3u8, thumbnail.jpg and one directory per
// rendition (index.m3u8 and its segments); master.m3u8 names each rendition playlist as
// <attempt>/<rendition>/index.m3u8, so the caller stores everything but the master under
// <attempt>/, next to which the master goes.
const (
	MasterPlaylist = "master.m3u8"
	Thumbnail      = "thumbnail.jpg"

	playlistName = "index.m3u8"

	contentTypePlaylist = "application/vnd.apple.mpegurl"
	contentTypeSegment  = "video/mp2t"
	contentTypeJPEG     = "image/jpeg"
)

// Encoding settings: 4 s segments make half the objects and requests of 2 s ones while a short
// video still starts quickly; a keyframe every 2 s, whatever the fps, so every segment starts on
// one.
const (
	segmentSeconds  = 4
	keyframeSeconds = 2
	audioBitrate    = 128_000
)

// Rendition is one HLS variant.
type Rendition struct {
	Name    string
	Width   int
	Height  int
	Bitrate int // target video bitrate, bits per second
}

// File is one output file, in upload order.
type File struct {
	Path        string // relative to the output directory, slash-separated
	ContentType string
}

// Result describes a finished transcode.
type Result struct {
	// Duration is read from the output playlists, not from the input's metadata.
	Duration time.Duration
	// Renditions run from the lowest bitrate to the highest.
	Renditions []Rendition
	// Files lists segments first, then the thumbnail, then the rendition playlists, and
	// master.m3u8 last, so uploading in this order never publishes a playlist before its
	// segments.
	Files []File
}

// rung is one step of the ladder, by the short side of the frame.
type rung struct {
	name    string
	short   int // 0 keeps the source size
	bitrate int
}

var ladder = []rung{
	{"360p", 360, 800_000},
	{"720p", 720, 2_500_000},
	{"1080p", 1080, 5_000_000},
}

// sourceRung is the single rendition of a source smaller than the lowest step.
var sourceRung = rung{"source", 0, 800_000}

type limits struct {
	probeTimeout  time.Duration
	ffmpegTimeout time.Duration // for the transcode and the thumbnail together
}

var defaultLimits = limits{probeTimeout: 30 * time.Second, ffmpegTimeout: 10 * time.Minute}

// Run probes input, then writes master.m3u8, <rendition>/index.m3u8 with its segments and
// thumbnail.jpg into outDir, the master naming its rendition playlists under attempt, which must
// be a canonical UUID. Both paths are local; input must be a file the caller downloaded.
func Run(ctx context.Context, input, outDir, attempt string) (Result, error) {
	return run(ctx, input, outDir, attempt, defaultLimits)
}

func run(ctx context.Context, input, outDir, attempt string, lim limits) (Result, error) {
	input, err := filepath.Abs(input)
	if err != nil {
		return Result{}, fmt.Errorf("transcode: %w", err)
	}
	outDir, err = filepath.Abs(outDir)
	if err != nil {
		return Result{}, fmt.Errorf("transcode: %w", err)
	}
	// The "file:" prefix keeps a name containing ':' from being read as another protocol.
	src := "file:" + input
	dirs := []string{filepath.Dir(input), outDir}

	p, err := probe(ctx, lim.probeTimeout, src, dirs)
	if err != nil {
		return Result{}, err
	}
	rungs := ladderFor(p.firstVideo())

	if err := os.MkdirAll(outDir, 0o750); err != nil {
		return Result{}, fmt.Errorf("transcode: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, lim.ffmpegTimeout)
	defer cancel()
	if err := runFFmpeg(ctx, dirs, hlsArgs(src, outDir, rungs, p.hasAudio())); err != nil {
		return Result{}, err
	}

	duration, err := readPlaylistDuration(filepath.Join(outDir, rungs[0].name, playlistName))
	if err != nil {
		return Result{}, err
	}
	if duration == 0 {
		return Result{}, fmt.Errorf("%w: no video frames decoded", ErrInvalidInput)
	}
	if err := runFFmpeg(ctx, dirs, thumbnailArgs(src, outDir, rungs[len(rungs)-1], duration)); err != nil {
		return Result{}, err
	}

	master, err := rewriteMaster(filepath.Join(outDir, MasterPlaylist), attempt)
	if err != nil {
		return Result{}, err
	}
	if !slices.EqualFunc(master.Renditions, rungs, func(r Rendition, g rung) bool { return r.Name == g.name }) {
		return Result{}, fmt.Errorf("transcode: %s does not list the renditions encoded", MasterPlaylist)
	}
	renditions := master.Renditions
	files, err := listFiles(outDir)
	if err != nil {
		return Result{}, err
	}
	return Result{Duration: duration, Renditions: renditions, Files: files}, nil
}

// ladderFor keeps the steps whose short side the source reaches (no upscaling); a source
// smaller than every step gets one rendition at its own size.
func ladderFor(v probeStream) []rung {
	short := min(v.Width, v.Height)
	var rungs []rung
	for _, r := range ladder {
		if r.short <= short {
			rungs = append(rungs, r)
		}
	}
	if len(rungs) == 0 {
		return []rung{sourceRung}
	}
	return rungs
}

// scaleFilter sets the short side of the frame to r.short and the other side to the even size
// that keeps the aspect ratio. It decides on the frame as decoded, after ffmpeg applies the
// rotation of a phone video, so portrait stays portrait.
func scaleFilter(r rung) string {
	if r.short == 0 {
		return "scale=w='trunc(iw/2)*2':h='trunc(ih/2)*2'"
	}
	return fmt.Sprintf("scale=w='if(gte(iw,ih),-2,%[1]d)':h='if(gte(iw,ih),%[1]d,-2)'", r.short)
}

// inputArgs opens the source under the whitelists (FF-1, FF-2).
func inputArgs(src string, extra ...string) []string {
	args := []string{
		"-hide_banner", "-nostdin", "-loglevel", "error", "-y",
		"-protocol_whitelist", "file",
		"-format_whitelist", formatWhitelist,
		"-codec_whitelist", decoderWhitelist,
	}
	args = append(args, extra...)
	return append(args, "-i", src)
}

// hlsArgs builds the single ffmpeg run that encodes every rendition.
func hlsArgs(src, outDir string, rungs []rung, audio bool) []string {
	// -t as an input option caps what is decoded, whatever the metadata claims (FF-3).
	args := inputArgs(src, "-t", strconv.Itoa(int(maxDuration.Seconds())))

	var graph strings.Builder
	fmt.Fprintf(&graph, "[0:v:0]split=%d", len(rungs))
	for i := range rungs {
		fmt.Fprintf(&graph, "[s%d]", i)
	}
	streamMap := make([]string, len(rungs))
	for i, r := range rungs {
		fmt.Fprintf(&graph, ";[s%d]%s[v%d]", i, scaleFilter(r), i)
	}
	args = append(args, "-filter_complex", graph.String())

	for i, r := range rungs {
		args = append(args, "-map", fmt.Sprintf("[v%d]", i))
		if audio {
			args = append(args, "-map", "0:a:0")
			streamMap[i] = fmt.Sprintf("v:%d,a:%d,name:%s", i, i, r.name)
		} else {
			streamMap[i] = fmt.Sprintf("v:%d,name:%s", i, r.name)
		}
	}

	// Always re-encode, never copy a stream (FF-7).
	args = append(args, "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p")
	for i, r := range rungs {
		args = append(args,
			fmt.Sprintf("-b:v:%d", i), strconv.Itoa(r.bitrate),
			fmt.Sprintf("-maxrate:v:%d", i), strconv.Itoa(r.bitrate*107/100),
			fmt.Sprintf("-bufsize:v:%d", i), strconv.Itoa(r.bitrate*3/2),
		)
	}
	args = append(args,
		"-force_key_frames", fmt.Sprintf("expr:gte(t,n_forced*%d)", keyframeSeconds),
		"-sc_threshold", "0",
	)
	if audio {
		args = append(args, "-c:a", "aac", "-b:a", strconv.Itoa(audioBitrate), "-ac", "2")
	}
	return append(args,
		// Drop container, stream and chapter metadata of the source (FF-7).
		"-map_metadata", "-1", "-map_chapters", "-1",
		"-f", "hls",
		"-hls_time", strconv.Itoa(segmentSeconds),
		"-hls_playlist_type", "vod",
		"-hls_segment_type", "mpegts",
		"-hls_segment_filename", filepath.Join(outDir, "%v", "seg_%03d.ts"),
		"-master_pl_name", MasterPlaylist,
		"-var_stream_map", strings.Join(streamMap, " "),
		filepath.Join(outDir, "%v", playlistName),
	)
}

// thumbnailMaxShort caps the thumbnail's short side. The thumbnail is the poster a page shows
// before the first frame, and on the feed it is the page's largest paint: at 720 px it weighs
// about half of a 1080 px frame. The poster covers a portrait column, so its height sets how
// sharp it looks: a portrait poster (720x1280) about fills a phone column at 1.75x, a landscape
// one (1280x720) is scaled up about 1.8x there and 2.2x on a 2x desktop screen. That lasts until
// the first frame, which the web player takes from the lowest rendition (360 px): softer still.
const thumbnailMaxShort = 720

// thumbnailArgs grabs one frame at 1 s, or mid-video for a video under 2 s, at the size of the
// top rendition, its short side capped at thumbnailMaxShort. JPEG quality 5 (of 2–31, lower is
// better) shows no visible loss on a poster and is about a fifth smaller than 3.
func thumbnailArgs(src, outDir string, top rung, duration time.Duration) []string {
	at := min(time.Second, duration/2)
	if top.short > thumbnailMaxShort {
		top.short = thumbnailMaxShort
	}
	args := inputArgs(src, "-ss", strconv.FormatFloat(at.Seconds(), 'f', 3, 64))
	return append(args,
		"-map", "0:v:0", "-frames:v", "1",
		"-vf", scaleFilter(top),
		"-map_metadata", "-1", "-map_chapters", "-1",
		"-q:v", "5", "-update", "1",
		filepath.Join(outDir, Thumbnail),
	)
}

// runFFmpeg runs ffmpeg after the input passed the probe: a failure now is not blamed on the file.
func runFFmpeg(ctx context.Context, dirs []string, args []string) error {
	return runTool(ctx, 0, io.Discard, dirs, "ffmpeg", args...)
}

// maxDetail caps the stderr line carried in an error.
const maxDetail = 512

// toolError is a failed ffprobe or ffmpeg run.
type toolError struct {
	tool   string
	exited bool // exited with a status; false when killed, timed out or never started
	detail string
	err    error
}

func (e *toolError) Error() string {
	if e.detail == "" {
		return fmt.Sprintf("transcode: %s: %v", e.tool, e.err)
	}
	return fmt.Sprintf("transcode: %s: %v: %s", e.tool, e.err, e.detail)
}

func (e *toolError) Unwrap() error { return e.err }

// runTool runs name from PATH with an empty environment (FF-2). With timeout > 0 the run gets
// its own deadline; when the deadline or ctx ends, exec.CommandContext kills the process
// (SIGKILL) and Wait reaps it before runTool returns. Each run is a span named after the tool,
// without its arguments: they hold the job's paths.
func runTool(ctx context.Context, timeout time.Duration, stdout io.Writer, dirs []string, name string, args ...string) (err error) {
	ctx, span := otel.Tracer("github.com/anhnvcoder/short-video-platform/services/media-worker/internal/transcode").Start(ctx, name)
	defer func() {
		if err != nil {
			span.SetStatus(codes.Error, name+" failed")
		}
		span.End()
	}()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, name, args...) //nolint:gosec // fixed tool names; the arguments are built by this package
	cmd.Env = []string{}
	cmd.Stdout = stdout
	stderr := &tailBuffer{max: 4096}
	cmd.Stderr = stderr

	err = cmd.Run()
	if err == nil {
		return nil
	}
	te := &toolError{tool: name, detail: stderr.lastLine(dirs), err: err}
	if ctxErr := ctx.Err(); ctxErr != nil {
		te.err = ctxErr
		return te
	}
	var exitErr *exec.ExitError
	te.exited = errors.As(err, &exitErr) && exitErr.Exited()
	return te
}

// tailBuffer keeps the last max bytes written, so a flood of error lines costs bounded memory.
type tailBuffer struct {
	buf []byte
	max int
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.buf = append(b.buf, p...)
	if over := len(b.buf) - b.max; over > 0 {
		b.buf = b.buf[over:]
	}
	return len(p), nil
}

// lastLine returns the last non-empty line, with the job's directories cut out of paths and
// cut to maxDetail bytes.
func (b *tailBuffer) lastLine(dirs []string) string {
	text := strings.TrimRight(string(b.buf), "\r\n")
	if i := strings.LastIndexAny(text, "\r\n"); i >= 0 {
		text = text[i+1:]
	}
	text = strings.ReplaceAll(text, "file:", "")
	for _, d := range dirs {
		text = strings.ReplaceAll(text, d+string(filepath.Separator), "")
	}
	if len(text) > maxDetail {
		text = text[:maxDetail]
	}
	return strings.ToValidUTF8(strings.TrimSpace(text), "")
}

// readPlaylistDuration is PlaylistDuration of the media playlist ffmpeg wrote at path.
func readPlaylistDuration(path string) (time.Duration, error) {
	data, err := os.ReadFile(path) //nolint:gosec // a playlist ffmpeg just wrote under the output directory
	if err != nil {
		return 0, fmt.Errorf("transcode: %w", err)
	}
	return PlaylistDuration(data)
}

// PlaylistDuration sums the #EXTINF durations of a media playlist.
func PlaylistDuration(data []byte) (time.Duration, error) {
	var total float64
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		v, ok := strings.CutPrefix(sc.Text(), "#EXTINF:")
		if !ok {
			continue
		}
		v, _, _ = strings.Cut(v, ",")
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return 0, fmt.Errorf("transcode: playlist: bad #EXTINF %q", v)
		}
		total += f
	}
	if err := sc.Err(); err != nil {
		return 0, fmt.Errorf("transcode: playlist: %w", err)
	}
	return time.Duration(total * float64(time.Second)).Round(time.Millisecond), nil
}

// Master is what a master playlist of Run says: the attempt directory its rendition playlists
// are under and the renditions, lowest bitrate first.
type Master struct {
	Attempt    string
	Renditions []Rendition
}

// LowestPlaylist is the path of the lowest rendition's playlist, relative to the master.
func (m Master) LowestPlaylist() string {
	return m.Attempt + "/" + m.Renditions[0].Name + "/" + playlistName
}

// knownRungs is every rendition Run may write, lowest bitrate first.
var knownRungs = append(slices.Clone(ladder), sourceRung)

// ParseMaster reads a master playlist written by Run, the one just transcoded or one stored
// before: every #EXT-X-STREAM-INF has a RESOLUTION and is followed by the URI
// <attempt>/<rendition>/index.m3u8, with one attempt, a canonical UUID, for all of them, and a
// rendition name of the ladder; the bitrate is the ladder's target for that name. Anything else
// is an error: a playlist the caller cannot vouch for, so it must not publish it.
func ParseMaster(data []byte) (Master, error) {
	var m Master
	lines := strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	found := map[string]Rendition{}
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		attrs, isVariant := strings.CutPrefix(line, "#EXT-X-STREAM-INF:")
		switch {
		case line == "" || (strings.HasPrefix(line, "#") && !isVariant && !strings.HasPrefix(line, "#EXT-X-MEDIA") &&
			!strings.HasPrefix(line, "#EXT-X-I-FRAME-STREAM-INF")):
			continue
		case !isVariant:
			return Master{}, fmt.Errorf("transcode: %s: unexpected line %q", MasterPlaylist, line)
		}
		if i+1 >= len(lines) {
			return Master{}, fmt.Errorf("transcode: %s: #EXT-X-STREAM-INF without a URI", MasterPlaylist)
		}
		i++
		uri := strings.TrimSpace(lines[i])
		parts := strings.Split(uri, "/")
		if len(parts) != 3 || parts[2] != playlistName {
			return Master{}, fmt.Errorf("transcode: %s: variant URI %q is not <attempt>/<rendition>/%s", MasterPlaylist, uri, playlistName)
		}
		if _, err := ids.Parse(parts[0]); err != nil {
			return Master{}, fmt.Errorf("transcode: %s: attempt %q is not a canonical UUID", MasterPlaylist, parts[0])
		}
		if m.Attempt != "" && parts[0] != m.Attempt {
			return Master{}, fmt.Errorf("transcode: %s: variants under two attempts", MasterPlaylist)
		}
		m.Attempt = parts[0]
		k := slices.IndexFunc(knownRungs, func(r rung) bool { return r.name == parts[1] })
		if k < 0 {
			return Master{}, fmt.Errorf("transcode: %s: unknown rendition %q", MasterPlaylist, parts[1])
		}
		if _, dup := found[parts[1]]; dup {
			return Master{}, fmt.Errorf("transcode: %s: rendition %s listed twice", MasterPlaylist, parts[1])
		}
		w, h, ok := resolution(attrs)
		if !ok {
			return Master{}, fmt.Errorf("transcode: %s lists no resolution for %s", MasterPlaylist, parts[1])
		}
		found[parts[1]] = Rendition{Name: parts[1], Width: w, Height: h, Bitrate: knownRungs[k].bitrate}
	}
	if len(found) == 0 {
		return Master{}, fmt.Errorf("transcode: %s lists no variant", MasterPlaylist)
	}
	for _, r := range knownRungs {
		if rd, ok := found[r.name]; ok {
			m.Renditions = append(m.Renditions, rd)
		}
	}
	return m, nil
}

// resolution reads RESOLUTION=<w>x<h> of an #EXT-X-STREAM-INF attribute list, the size ffmpeg
// actually encoded. A quoted value with commas (CODECS) splits into pieces that never start
// with RESOLUTION=.
func resolution(attrs string) (int, int, bool) {
	for a := range strings.SplitSeq(attrs, ",") {
		res, ok := strings.CutPrefix(a, "RESOLUTION=")
		if !ok {
			continue
		}
		w, h, _ := strings.Cut(res, "x")
		wi, err1 := strconv.Atoi(w)
		hi, err2 := strconv.Atoi(h)
		if err1 == nil && err2 == nil && wi > 0 && hi > 0 {
			return wi, hi, true
		}
	}
	return 0, 0, false
}

// rewriteMaster puts attempt/ in front of the URI after each #EXT-X-STREAM-INF of the master
// playlist ffmpeg wrote at path, then reads the result back with ParseMaster. A master with
// another tag carrying a URI (#EXT-X-MEDIA, #EXT-X-I-FRAME-STREAM-INF) is an error: ffmpeg writes
// none for this ladder, and one left unchanged would send a player to the wrong path.
func rewriteMaster(path, attempt string) (Master, error) {
	data, err := os.ReadFile(path) //nolint:gosec // the master playlist ffmpeg just wrote
	if err != nil {
		return Master{}, fmt.Errorf("transcode: %w", err)
	}
	lines := strings.Split(string(data), "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		switch {
		case strings.HasPrefix(line, "#EXT-X-MEDIA"), strings.HasPrefix(line, "#EXT-X-I-FRAME-STREAM-INF"):
			return Master{}, fmt.Errorf("transcode: %s: unexpected tag with a URI: %q", MasterPlaylist, line)
		case strings.HasPrefix(line, "#EXT-X-STREAM-INF:") && i+1 < len(lines):
			i++
			lines[i] = attempt + "/" + strings.TrimSpace(lines[i])
		}
	}
	data = []byte(strings.Join(lines, "\n"))
	m, err := ParseMaster(data)
	if err != nil {
		return Master{}, err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil { //nolint:gosec // the master playlist ffmpeg just wrote
		return Master{}, fmt.Errorf("transcode: %w", err)
	}
	return m, nil
}

// listFiles lists outDir in upload order: segments, thumbnail, rendition playlists, master.
func listFiles(outDir string) ([]File, error) {
	type entry struct {
		File
		rank int
	}
	var entries []entry
	err := filepath.WalkDir(outDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(outDir, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		switch {
		case strings.HasSuffix(rel, ".ts"):
			entries = append(entries, entry{File{rel, contentTypeSegment}, 0})
		case rel == Thumbnail:
			entries = append(entries, entry{File{rel, contentTypeJPEG}, 1})
		case rel == MasterPlaylist:
			entries = append(entries, entry{File{rel, contentTypePlaylist}, 3})
		case strings.HasSuffix(rel, "/"+playlistName):
			entries = append(entries, entry{File{rel, contentTypePlaylist}, 2})
		default:
			return fmt.Errorf("unexpected output file %s", rel)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("transcode: %w", err)
	}
	slices.SortFunc(entries, func(a, b entry) int {
		if a.rank != b.rank {
			return a.rank - b.rank
		}
		return strings.Compare(a.Path, b.Path)
	})
	files := make([]File, len(entries))
	for i, e := range entries {
		files[i] = e.File
	}
	return files, nil
}
