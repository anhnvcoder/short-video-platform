// Command fakefollows produces fake follow events for the freshness measurement
// (deploy/compose/drills/measure-freshness.sh). It feeds feed-service's real consumer, which is
// what the measurement is about, and does it without registering thousands of users (Register is
// slow by design); the matching unfollow undoes it. For the local stack only.
//
// It impersonates user-service: it writes svp.user.v1.FollowEvent records straight to
// user.follows.v1, which nothing stops it from doing until the broker has ACLs (threat model IN-4,
// stage 4). feed-service then holds follows that user-service never had: its copy of the follow
// graph disagrees with user-service until `unfollow` is run with the same ids file.
//
//	fakefollows follow   -followee <uuid> -n <count> -out <file> [-brokers 127.0.0.1:19092]
//	fakefollows unfollow -followee <uuid> -in <file>              [-brokers 127.0.0.1:19092]
//
// follow makes count new UUIDv7 follower ids, writes them to the file (one per line) before
// producing anything, so an interrupted run can still be undone, then produces one user.followed
// per id. unfollow produces user.unfollowed for every id in the file. Records are keyed by
// follower_id like user-service's, so a follower's unfollow lands on the partition of its follow,
// after it.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"

	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	userv1 "github.com/anhnvcoder/svp-backend/gen/go/svp/user/v1"
	"github.com/anhnvcoder/svp-backend/internal/ids"
	"github.com/anhnvcoder/svp-backend/internal/kafkax"
	"github.com/anhnvcoder/svp-backend/internal/outbox"
)

// topic is user-service's follow topic (services/user-service/internal/server.TopicUserFollows).
const topic = "user.follows.v1"

// batchSize is the number of records per ProduceSync: big enough that a round trip carries
// thousands of events, below franz-go's default limit of 10,000 buffered records.
const batchSize = 5000

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "fakefollows:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, log io.Writer) error {
	if len(args) == 0 || (args[0] != "follow" && args[0] != "unfollow") {
		return errors.New("usage: fakefollows follow|unfollow -followee <uuid> [flags]")
	}
	mode := args[0]
	fs := flag.NewFlagSet("fakefollows "+mode, flag.ContinueOnError)
	fs.SetOutput(log)
	brokers := fs.String("brokers", "127.0.0.1:19092", "Kafka brokers, comma-separated host:port")
	followee := fs.String("followee", "", "id of the user the fake followers follow")
	var n int
	var file string
	if mode == "follow" {
		fs.IntVar(&n, "n", 0, "number of fake followers to create")
		fs.StringVar(&file, "out", "", "file to write the follower ids to")
	} else {
		fs.StringVar(&file, "in", "", "file with the follower ids written by follow")
	}
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	if _, err := ids.Parse(*followee); err != nil {
		return fmt.Errorf("-followee: %w", err)
	}
	if file == "" {
		return errors.New("the ids file is required (-out for follow, -in for unfollow)")
	}

	var followers []string
	if mode == "follow" {
		if n <= 0 {
			return fmt.Errorf("-n must be positive (got %d)", n)
		}
		followers = make([]string, n)
		for i := range followers {
			followers[i] = ids.New()
		}
		if err := writeIDs(file, followers); err != nil {
			return err
		}
	} else {
		var err error
		if followers, err = readIDs(file); err != nil {
			return err
		}
	}

	cl, err := kafkax.NewClient(*brokers, "fakefollows")
	if err != nil {
		return err
	}
	defer cl.Close()
	for start := 0; start < len(followers); start += batchSize {
		batch := followers[start:min(start+batchSize, len(followers))]
		rs := make([]*kgo.Record, len(batch))
		for i, f := range batch {
			if rs[i], err = record(mode, f, *followee); err != nil {
				return err
			}
		}
		if err := kafkax.Produce(ctx, cl, rs...); err != nil {
			return fmt.Errorf("after %d of %d events: %w", start, len(followers), err)
		}
		_, _ = fmt.Fprintf(log, "fakefollows: produced %d/%d user.%sed for %s\n", start+len(batch), len(followers), mode, *followee)
	}
	return nil
}

// record builds the user.followed or user.unfollowed record of follower.
func record(mode, follower, followee string) (*kgo.Record, error) {
	ev := &userv1.FollowEvent{Meta: outbox.NewMeta()}
	if mode == "follow" {
		ev.Event = &userv1.FollowEvent_UserFollowed{UserFollowed: &userv1.UserFollowed{FollowerId: follower, FolloweeId: followee}}
	} else {
		ev.Event = &userv1.FollowEvent_UserUnfollowed{UserUnfollowed: &userv1.UserUnfollowed{FollowerId: follower, FolloweeId: followee}}
	}
	payload, err := proto.Marshal(ev)
	if err != nil {
		return nil, fmt.Errorf("marshal event: %w", err)
	}
	return &kgo.Record{Topic: topic, Key: []byte(follower), Value: payload}, nil
}

// writeIDs writes list to path, one per line, through a temporary file renamed at the end, so path
// never holds half a list.
func writeIDs(path string, list []string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(list, "\n")+"\n"), 0o600); err != nil {
		return fmt.Errorf("write ids file: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("write ids file: %w", err)
	}
	return nil
}

// readIDs reads the ids written by writeIDs and checks each is a UUID.
func readIDs(path string) ([]string, error) {
	f, err := os.Open(path) //nolint:gosec // the ids file named on the command line by its operator
	if err != nil {
		return nil, fmt.Errorf("read ids file: %w", err)
	}
	defer func() { _ = f.Close() }()
	var out []string
	sc := bufio.NewScanner(f)
	for line := 1; sc.Scan(); line++ {
		if _, err := ids.Parse(sc.Text()); err != nil {
			return nil, fmt.Errorf("ids file line %d: %w", line, err)
		}
		out = append(out, sc.Text())
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read ids file: %w", err)
	}
	if len(out) == 0 {
		return nil, errors.New("ids file is empty")
	}
	return out, nil
}
