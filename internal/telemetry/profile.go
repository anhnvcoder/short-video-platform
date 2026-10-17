package telemetry

import (
	"context"
	"net/http"

	"github.com/grafana/pyroscope-go"
)

func startProfiler(service, address string) (func(context.Context) error, error) {
	ctx, cancel := context.WithCancel(context.Background())
	client := &profileClient{ctx: ctx, client: &http.Client{
		Timeout:       exportTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
	p, err := pyroscope.Start(pyroscope.Config{
		ApplicationName: service,
		ServerAddress:   address,
		ProfileTypes: []pyroscope.ProfileType{
			pyroscope.ProfileCPU, pyroscope.ProfileAllocSpace, pyroscope.ProfileInuseSpace, pyroscope.ProfileGoroutines,
		},
		HTTPClient: client,
	})
	if err != nil {
		cancel()
		return nil, err
	}
	return func(context.Context) error {
		// pyroscope.Stop has no context and otherwise waits up to 30 s on network I/O.
		cancel()
		return p.Stop()
	}, nil
}

type profileClient struct {
	ctx    context.Context
	client *http.Client
}

func (c *profileClient) Do(req *http.Request) (*http.Response, error) {
	// Pyroscope supplies background request contexts; keep this context alive through body reads.
	return c.client.Do(req.WithContext(c.ctx))
}
