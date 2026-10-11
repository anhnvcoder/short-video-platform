package transcode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
)

// Demuxer and decoder names handed to ffprobe and ffmpeg (FF-1, FF-2), checked against
// `ffmpeg -demuxers` and `ffmpeg -decoders` of ffmpeg 9.0.2. A whitelist entry matches any
// name of a demuxer, so "mov" admits "mov,mp4,m4a,3gp,3g2,mj2" and "matroska" admits
// "matroska,webm"; playlist and reference demuxers (hls, concat, ...) stay out.
// The decoder list holds every decoder ffmpeg may pick for an allowed codec: AV1 is decoded
// by libdav1d when the build has it, MP3 by mp3float first.
const (
	formatWhitelist  = "mov,matroska"
	decoderWhitelist = "h264,hevc,vp8,vp9,av1,libdav1d,aac,mp3float,mp3,opus,vorbis"
)

// Containers and codecs accepted after probing, as ffprobe names them.
var (
	allowedFormats = []string{"mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm"}
	videoCodecs    = []string{"h264", "hevc", "vp8", "vp9", "av1"}
	audioCodecs    = []string{"aac", "mp3", "opus", "vorbis"}
)

// Input limits (FF-3).
const (
	maxStreams  = 8
	maxSide     = 4096
	maxFPS      = 120
	maxDuration = 180 * time.Second
	// durationSlack absorbs container rounding: a 180 s video may report 180.02 s.
	durationSlack = time.Second
	// maxProbeOutput caps the JSON read from ffprobe; the entries asked for fit in a few KiB.
	maxProbeOutput = 64 << 10
)

// probeEntries lists the only fields ffprobe prints. Tags are left out so a crafted file cannot
// inflate the output with huge metadata values.
const probeEntries = "format=format_name,duration:stream=codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,duration"

type probeStream struct {
	CodecType    string `json:"codec_type"`
	CodecName    string `json:"codec_name"`
	Width        int    `json:"width"`
	Height       int    `json:"height"`
	AvgFrameRate string `json:"avg_frame_rate"`
	RFrameRate   string `json:"r_frame_rate"`
	Duration     string `json:"duration"`
}

type probeResult struct {
	Streams []probeStream `json:"streams"`
	Format  struct {
		FormatName string `json:"format_name"`
		Duration   string `json:"duration"`
	} `json:"format"`
}

// probe runs ffprobe on input (a "file:" URL) and checks the result against the limits.
func probe(ctx context.Context, timeout time.Duration, input string, dirs []string) (probeResult, error) {
	args := []string{
		"-hide_banner", "-v", "error",
		"-protocol_whitelist", "file",
		"-format_whitelist", formatWhitelist,
		"-codec_whitelist", decoderWhitelist,
		"-show_entries", probeEntries,
		"-of", "json",
		input,
	}
	out := &limitedBuffer{max: maxProbeOutput}
	if err := runTool(ctx, timeout, out, dirs, "ffprobe", args...); err != nil {
		// ffprobe exits with a code when it cannot open, demux or decode the file, or when a
		// whitelist refuses it: the file is the problem. Killed, timed out or not started is not.
		var te *toolError
		if errors.As(err, &te) && te.exited {
			return probeResult{}, fmt.Errorf("%w: %s", ErrInvalidInput, te.detail)
		}
		return probeResult{}, err
	}
	if out.overflow {
		return probeResult{}, fmt.Errorf("%w: ffprobe output exceeds %d bytes", ErrInvalidInput, maxProbeOutput)
	}
	var p probeResult
	if err := json.Unmarshal(out.buf, &p); err != nil {
		return probeResult{}, fmt.Errorf("%w: unreadable ffprobe output: %v", ErrInvalidInput, err) //nolint:errorlint // the JSON error is detail text, not a cause to match
	}
	return p, p.check()
}

// check returns ErrInvalidInput for a container, codec, stream or size outside the limits and
// ErrDurationExceeded for a declared duration over the limit. The duration is checked last: a
// file that breaks another rule is invalid whatever its length.
func (p probeResult) check() error {
	if !slices.Contains(allowedFormats, p.Format.FormatName) {
		return invalid("container %q is not allowed", p.Format.FormatName)
	}
	if len(p.Streams) > maxStreams {
		return invalid("%d streams, at most %d allowed", len(p.Streams), maxStreams)
	}
	videos := 0
	for i, s := range p.Streams {
		switch s.CodecType {
		case "video":
			videos++
			if !slices.Contains(videoCodecs, s.CodecName) {
				return invalid("stream %d: video codec %q is not allowed", i, s.CodecName)
			}
			if s.Width < 2 || s.Height < 2 || max(s.Width, s.Height) > maxSide {
				return invalid("stream %d: size %dx%d is outside 2 to %d pixels", i, s.Width, s.Height, maxSide)
			}
			fps := frameRate(s.AvgFrameRate)
			if fps == 0 {
				fps = frameRate(s.RFrameRate)
			}
			if fps > maxFPS {
				return invalid("stream %d: %.2f fps, at most %d allowed", i, fps, maxFPS)
			}
		case "audio":
			if !slices.Contains(audioCodecs, s.CodecName) {
				return invalid("stream %d: audio codec %q is not allowed", i, s.CodecName)
			}
		case "data":
			// Timecode and camera metadata tracks (common in phone MOV files) have no decoder
			// and are never mapped to the output.
		default:
			return invalid("stream %d: %q streams are not allowed", i, s.CodecType)
		}
	}
	if videos == 0 {
		return invalid("no video stream")
	}
	if d, ok := p.duration(); ok && d > maxDuration+durationSlack {
		return fmt.Errorf("%w: %.1f s, at most %.0f s allowed", ErrDurationExceeded, d.Seconds(), maxDuration.Seconds())
	}
	return nil
}

// duration returns the declared length: the container's, else the longest stream's. A file may
// declare none (WebM recorded by a browser); ffmpeg's -t still caps what gets decoded.
func (p probeResult) duration() (time.Duration, bool) {
	if d, ok := seconds(p.Format.Duration); ok {
		return d, true
	}
	var longest time.Duration
	found := false
	for _, s := range p.Streams {
		if d, ok := seconds(s.Duration); ok && d > longest {
			longest, found = d, true
		}
	}
	return longest, found
}

// firstVideo returns the stream ffmpeg maps as 0:v:0.
func (p probeResult) firstVideo() probeStream {
	for _, s := range p.Streams {
		if s.CodecType == "video" {
			return s
		}
	}
	return probeStream{}
}

func (p probeResult) hasAudio() bool {
	return slices.ContainsFunc(p.Streams, func(s probeStream) bool { return s.CodecType == "audio" })
}

func invalid(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidInput, fmt.Sprintf(format, args...))
}

func seconds(s string) (time.Duration, bool) {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) || f < 0 {
		return 0, false
	}
	return time.Duration(f * float64(time.Second)), true
}

// frameRate parses an ffprobe rational such as "30000/1001"; 0 means unknown.
func frameRate(r string) float64 {
	num, den, ok := strings.Cut(r, "/")
	if !ok {
		return 0
	}
	n, err1 := strconv.ParseFloat(num, 64)
	d, err2 := strconv.ParseFloat(den, 64)
	if err1 != nil || err2 != nil || d <= 0 || n < 0 || math.IsInf(n, 0) {
		return 0
	}
	return n / d
}

// limitedBuffer keeps the first max bytes written and records whether more came.
type limitedBuffer struct {
	buf      []byte
	max      int
	overflow bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	keep := p
	if room := b.max - len(b.buf); len(keep) > room {
		b.overflow = true
		keep = keep[:max(room, 0)]
	}
	b.buf = append(b.buf, keep...)
	// Report everything as written: the copy from the pipe keeps draining, so the child never
	// blocks on a full pipe.
	return len(p), nil
}
