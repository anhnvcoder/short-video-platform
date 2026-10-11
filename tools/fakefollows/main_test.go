package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	userv1 "github.com/anhnvcoder/short-video-platform/gen/go/svp/user/v1"
	"github.com/anhnvcoder/short-video-platform/internal/ids"
)

// cluster starts an in-memory Kafka with the follow topic (3 partitions, like the stack) and
// returns its broker list.
func cluster(t *testing.T) string {
	t.Helper()
	c, err := kfake.NewCluster(kfake.NumBrokers(1), kfake.SeedTopics(3, topic))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
	return strings.Join(c.ListenAddrs(), ",")
}

// consumeAll reads want records from the follow topic, from the start.
func consumeAll(t *testing.T, brokers string, want int) []*kgo.Record {
	t.Helper()
	cl, err := kgo.NewClient(kgo.SeedBrokers(strings.Split(brokers, ",")...), kgo.ConsumeTopics(topic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	var out []*kgo.Record
	for len(out) < want {
		fetches := cl.PollFetches(ctx)
		if err := fetches.Err0(); err != nil {
			t.Fatalf("poll after %d of %d records: %v", len(out), want, err)
		}
		out = append(out, fetches.Records()...)
	}
	if len(out) != want {
		t.Fatalf("got %d records, want %d", len(out), want)
	}
	return out
}

func runTool(t *testing.T, args ...string) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	return run(ctx, args, io.Discard)
}

func TestFollowThenUnfollowProducesEventsForTheSameIDs(t *testing.T) {
	brokers := cluster(t)
	followee := ids.New()
	file := filepath.Join(t.TempDir(), "ids")
	const n = 2*batchSize + 7 // three batches, the last one short

	if err := runTool(t, "follow", "-brokers", brokers, "-followee", followee, "-n", strconv.Itoa(n), "-out", file); err != nil {
		t.Fatal(err)
	}
	if err := runTool(t, "unfollow", "-brokers", brokers, "-followee", followee, "-in", file); err != nil {
		t.Fatal(err)
	}

	written, err := readIDs(file)
	if err != nil {
		t.Fatal(err)
	}
	if len(written) != n {
		t.Fatalf("ids file has %d ids, want %d", len(written), n)
	}
	if info, err := os.Stat(file); err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("ids file mode = %v (err %v), want 0600", info.Mode().Perm(), err)
	}
	if _, err := os.Stat(file + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temporary ids file left behind (stat err %v)", err)
	}

	// Per follower: the partition of its follow, and whether its unfollow came after it there.
	followPartition := map[string]int32{}
	eventIDs := map[string]bool{}
	unfollowed := 0
	for _, r := range consumeAll(t, brokers, 2*n) {
		var ev userv1.FollowEvent
		if err := proto.Unmarshal(r.Value, &ev); err != nil {
			t.Fatalf("record at %d/%d does not parse: %v", r.Partition, r.Offset, err)
		}
		if _, err := ids.Parse(ev.GetMeta().GetEventId()); err != nil || ev.GetMeta().GetOccurredAt() == nil {
			t.Fatalf("record meta = %v, want a UUID event_id and occurred_at", ev.GetMeta())
		}
		if eventIDs[ev.GetMeta().GetEventId()] {
			t.Fatalf("event_id %s used twice", ev.GetMeta().GetEventId())
		}
		eventIDs[ev.GetMeta().GetEventId()] = true
		key := string(r.Key)
		switch e := ev.GetEvent().(type) {
		case *userv1.FollowEvent_UserFollowed:
			if e.UserFollowed.GetFollowerId() != key || e.UserFollowed.GetFolloweeId() != followee {
				t.Fatalf("user.followed %v with key %s, want follower = key and followee %s", e.UserFollowed, key, followee)
			}
			followPartition[key] = r.Partition
		case *userv1.FollowEvent_UserUnfollowed:
			if e.UserUnfollowed.GetFollowerId() != key || e.UserUnfollowed.GetFolloweeId() != followee {
				t.Fatalf("user.unfollowed %v with key %s, want follower = key and followee %s", e.UserUnfollowed, key, followee)
			}
			p, ok := followPartition[key]
			if !ok || p != r.Partition {
				t.Fatalf("user.unfollowed of %s on partition %d is not after its user.followed there", key, r.Partition)
			}
			unfollowed++
		default:
			t.Fatalf("unexpected event %T", e)
		}
	}
	if len(followPartition) != n || unfollowed != n {
		t.Fatalf("got %d followed and %d unfollowed, want %d of each", len(followPartition), unfollowed, n)
	}
	for _, id := range written {
		if _, ok := followPartition[id]; !ok {
			t.Fatalf("id %s from the file has no user.followed", id)
		}
	}
}

func TestRejectsBadArguments(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	if err := os.WriteFile(good, []byte(ids.New()+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(dir, "bad")
	if err := os.WriteFile(bad, []byte(ids.New()+"\nnot-a-uuid\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	followee := ids.New()
	for name, args := range map[string][]string{
		"no mode":           {},
		"unknown mode":      {"block", "-followee", followee},
		"followee not uuid": {"follow", "-followee", "ABC", "-n", "1", "-out", filepath.Join(dir, "x")},
		"n zero":            {"follow", "-followee", followee, "-n", "0", "-out", filepath.Join(dir, "x")},
		"no out":            {"follow", "-followee", followee, "-n", "1"},
		"no in":             {"unfollow", "-followee", followee},
		"missing file":      {"unfollow", "-followee", followee, "-in", filepath.Join(dir, "none")},
		"bad id in file":    {"unfollow", "-followee", followee, "-in", bad},
		"empty file":        {"unfollow", "-followee", followee, "-in", empty},
		"extra argument":    {"unfollow", "-followee", followee, "-in", good, "more"},
		"empty brokers":     {"unfollow", "-followee", followee, "-in", good, "-brokers", " "},
	} {
		t.Run(name, func(t *testing.T) {
			if err := runTool(t, args...); err == nil {
				t.Fatalf("run(%q) = nil, want an error", args)
			}
		})
	}
	if _, err := os.Stat(filepath.Join(dir, "x")); !os.IsNotExist(err) {
		t.Errorf("a rejected follow wrote the ids file (stat err %v)", err)
	}
}
