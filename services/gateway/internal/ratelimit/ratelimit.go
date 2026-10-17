// Package ratelimit is the gateway's rate limiter (docs/adr/0010-redis-ratelimit-cache-resilience-stage2c.md,
// section 2): GCRA in one Lua script on Redis, shared by every gateway instance, and the same
// algorithm in memory for the routes that must stay limited while Redis fails.
//
// Each route class decides what happens when Redis fails or takes longer than storeTimeout
// (threat model RL-2): a soft-closed class (register, login, upload) falls back to an in-memory
// counter per instance with lower limits; an open class (write, read, view-once) lets the
// request through.
package ratelimit

import (
	"context"
	"errors"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

const (
	// defaultStoreTimeout bounds every Redis call unless WithStoreTimeout sets another bound; an
	// error or a timeout both count as Redis failing.
	defaultStoreTimeout = 50 * time.Millisecond
	// warnEvery spaces out the WARN logged while Redis fails.
	warnEvery = 10 * time.Second
	// viewWindow is how long a (user, video) view blocks the next one (threat model RL-3).
	viewWindow = 60 * time.Second
)

// Limit is a GCRA limit: Rate requests per Period on average, and up to Burst at once.
type Limit struct {
	Rate   int
	Period time.Duration
	Burst  int
}

// interval is the emission interval T: one request every T once the burst is spent.
func (l Limit) interval() time.Duration {
	return l.Period / time.Duration(l.Rate)
}

// Class is a route class: its name (part of the key), its limit, and the in-memory limit used
// while Redis fails. A zero Fallback means the class fails open.
type Class struct {
	Name     string
	Limit    Limit
	Fallback Limit
}

// The classes of ADR-0010 section 2, each sized so that a real user never reaches the limit
// while password guessing, mass sign-ups and junk writes slow down. Fallback limits are half of
// the Redis ones.
var (
	Register   = Class{Name: "register", Limit: Limit{60, time.Hour, 20}, Fallback: Limit{30, time.Hour, 10}}
	LoginIP    = Class{Name: "login-ip", Limit: Limit{60, time.Minute, 30}, Fallback: Limit{30, time.Minute, 15}}
	LoginEmail = Class{Name: "login-email", Limit: Limit{10, time.Hour, 5}, Fallback: Limit{5, time.Hour, 3}}
	Upload     = Class{Name: "upload", Limit: Limit{30, time.Hour, 10}, Fallback: Limit{15, time.Hour, 5}}
	Write      = Class{Name: "write", Limit: Limit{120, time.Minute, 60}}
	Read       = Class{Name: "read", Limit: Limit{600, time.Minute, 200}}
)

// classes are the classes above, whose decision series New creates at zero.
var classes = []Class{Register, LoginIP, LoginEmail, Upload, Write, Read}

// gcraScript is the GCRA step, atomic in Redis. KEYS[1] holds the theoretical arrival time
// (TAT) in Unix milliseconds; ARGV[1] is the interval T and ARGV[2] the burst. Time comes from
// Redis, so gateway instances never disagree about it. A request is allowed when the new TAT is
// at most T*burst ahead of now; the key then lives exactly until the bucket is full again. A
// refused request leaves the TAT as it was and returns the wait in milliseconds.
var gcraScript = redis.NewScript(`
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
local interval = tonumber(ARGV[1])
local limit = interval * tonumber(ARGV[2])
local tat = tonumber(redis.call('GET', KEYS[1])) or now
if tat < now then
  tat = now
end
local ahead = tat + interval - now
if ahead > limit then
  return {0, ahead - limit}
end
redis.call('SET', KEYS[1], now + ahead, 'PX', ahead)
return {1, 0}
`)

// Limiter checks requests against the classes, on Redis with the in-memory fallback.
type Limiter struct {
	client *redis.Client
	// prefix starts every key (svp:gw: in production).
	prefix string
	mem    *memory
	// storeTimeout bounds every Redis call.
	storeTimeout time.Duration
	// lastWarn is the Unix nanoseconds of the last "store unavailable" WARN.
	lastWarn atomic.Int64
	// decisions counts every Allow answer (svp.ratelimit.decisions).
	decisions metric.Int64Counter
}

// Option changes a Limiter built by New.
type Option func(*Limiter)

// WithStoreTimeout bounds every Redis call by d instead of defaultStoreTimeout. Tests that count
// requests on Redis use a longer bound, so a slow test run does not take the fallback.
func WithStoreTimeout(d time.Duration) Option {
	return func(l *Limiter) { l.storeTimeout = d }
}

// New returns a Limiter on client with keys under prefix. It does not touch Redis.
//
// Every Allow answer is counted by the global OTel meter provider in svp.ratelimit.decisions,
// labelled class, result (allowed or limited) and store (redis, or fallback when Redis failed),
// so the fallback in use is visible (threat model RL-2; docs/adr/0011-observability-stage3.md,
// section 5). An answer to a request cancelled before Redis answered is not counted. New adds 0
// to every series of the classes of ADR-0010, so they exist before the first request.
func New(client *redis.Client, prefix string, opts ...Option) *Limiter {
	l := &Limiter{client: client, prefix: prefix, mem: newMemory(time.Now), storeTimeout: defaultStoreTimeout}
	for _, opt := range opts {
		opt(l)
	}
	decisions, err := otel.Meter("github.com/anhnvcoder/short-video-platform/services/gateway/internal/ratelimit").
		Int64Counter("svp.ratelimit.decisions")
	if err != nil {
		// The SDK still returns a working instrument along with the error.
		otel.Handle(err)
	}
	l.decisions = decisions
	for _, c := range classes {
		for _, allowed := range []bool{true, false} {
			for _, store := range []string{storeRedis, storeFallback} {
				l.count(context.Background(), c, allowed, store, 0)
			}
		}
	}
	return l
}

// The store label of svp.ratelimit.decisions.
const (
	storeRedis    = "redis"
	storeFallback = "fallback"
)

// Allow counts one request of class c by id (a client IP, a user id, ...) and reports whether it
// may go on; when it may not, retryAfter is how long until it would. Allow never fails: when
// Redis fails, a soft-closed class is checked in memory and an open class is allowed.
func (l *Limiter) Allow(ctx context.Context, c Class, id string) (ok bool, retryAfter time.Duration) {
	ok, retryAfter, err := l.allowRedis(ctx, c.Limit, l.prefix+"rl:"+c.Name+":"+id)
	if err == nil {
		l.count(ctx, c, ok, storeRedis, 1)
		return ok, retryAfter
	}
	l.warnUnlessGone(ctx, err)
	ok, retryAfter = true, 0
	if c.Fallback != (Limit{}) {
		ok, retryAfter = l.mem.allow(c.Name+":"+id, c.Fallback)
	}
	// Like the WARN, the decision counts under fallback only when Redis failed: when the request
	// was already cancelled or past its deadline, the Redis call failed because of the request.
	if ctx.Err() == nil {
		l.count(ctx, c, ok, storeFallback, 1)
	}
	return ok, retryAfter
}

// count adds n to the decisions of class c with result allowed in store.
func (l *Limiter) count(ctx context.Context, c Class, allowed bool, store string, n int64) {
	result := "limited"
	if allowed {
		result = "allowed"
	}
	l.decisions.Add(ctx, n, metric.WithAttributes(
		attribute.String("class", c.Name),
		attribute.String("result", result),
		attribute.String("store", store),
	))
}

func (l *Limiter) allowRedis(ctx context.Context, lim Limit, key string) (bool, time.Duration, error) {
	ctx, cancel := context.WithTimeout(ctx, l.storeTimeout)
	defer cancel()
	res, err := gcraScript.Run(ctx, l.client, []string{key}, lim.interval().Milliseconds(), lim.Burst).Int64Slice()
	if err != nil {
		return false, 0, err
	}
	if len(res) != 2 {
		return false, 0, errors.New("ratelimit: unexpected script result")
	}
	return res[0] == 1, time.Duration(res[1]) * time.Millisecond, nil
}

// ViewClaim is the answer of ClaimView.
type ViewClaim int

const (
	// ViewClaimed is the first view of the pair in the window; its key is now set.
	ViewClaimed ViewClaim = iota
	// ViewRepeated means a view of the pair was already counted in the window.
	ViewRepeated
	// ViewUnchecked means Redis failed: the view goes on (open) and no key was set.
	ViewUnchecked
)

// ClaimView marks a view of videoID by userID for viewWindow (SET NX PX). The caller passes
// only a canonical video id, so one video has one key and junk ids write nothing.
func (l *Limiter) ClaimView(ctx context.Context, userID, videoID string) ViewClaim {
	storeCtx, cancel := context.WithTimeout(ctx, l.storeTimeout)
	defer cancel()
	set, err := l.client.SetNX(storeCtx, l.viewKey(userID, videoID), 1, viewWindow).Result()
	if err != nil {
		l.warnUnlessGone(ctx, err)
		return ViewUnchecked
	}
	if !set {
		return ViewRepeated
	}
	return ViewClaimed
}

// ReleaseView deletes the key ClaimView set, so a client retrying a view that was not recorded
// is counted. It is best-effort: a failure is only logged.
func (l *Limiter) ReleaseView(ctx context.Context, userID, videoID string) {
	ctx, cancel := context.WithTimeout(ctx, l.storeTimeout)
	defer cancel()
	if err := l.client.Del(ctx, l.viewKey(userID, videoID)).Err(); err != nil {
		l.warn(ctx, err)
	}
}

func (l *Limiter) viewKey(userID, videoID string) string {
	return l.prefix + "rl:view-once:" + userID + ":" + videoID
}

// warnUnlessGone warns that Redis failed, unless the request of ctx was already cancelled or
// past its deadline: the Redis call then failed because of the request, not of Redis.
func (l *Limiter) warnUnlessGone(ctx context.Context, err error) {
	if ctx.Err() != nil {
		return
	}
	l.warn(ctx, err)
}

// warn logs that Redis failed, at most once every warnEvery across all requests.
func (l *Limiter) warn(ctx context.Context, err error) {
	now := time.Now().UnixNano()
	last := l.lastWarn.Load()
	if now-last < int64(warnEvery) || !l.lastWarn.CompareAndSwap(last, now) {
		return
	}
	slog.WarnContext(ctx, "rate limit store unavailable, using fallback", slog.String("error", err.Error()))
}
