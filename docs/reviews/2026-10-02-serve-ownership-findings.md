# Version-matched Serve ownership evidence

Installed Tailscale 1.102.4 reports commit 3caf7d9e7dcaba589cfc58beda596929733e4fea. GitHub refs/tags/v1.102.4 resolves to that exact commit. Read-only help confirms foreground mode without --bg. No Serve mutation or live route test has occurred.

The CLI creates a WatchIPNBus foreground session and attaches config under its session ID. GetServeConfig retains an ETag; SetServeConfig sends If-Match. Backend validation rejects new foreground ports already in use, and foreground-session deletion is scoped under its mutex. This is source evidence, not a claim of actual cleanup readback. The implementation must terminate only its owned foreground CLI/supervisor, never port-wide off/reset, and verify unrelated mappings afterward. A status-only check cannot replace these version-matched guarantees. Fail closed for an unsupported installed version/schema.

## cmd/tailscale/cli/serve_v2.go

Primary source: https://github.com/tailscale/tailscale/blob/3caf7d9e7dcaba589cfc58beda596929733e4fea/cmd/tailscale/cli/serve_v2.go

Full source SHA256: 6bedc8ae035963f443c7176f69fe631f802a524a216577df6c1981afdb54ae95

Lines 490-510

```go
		wantFg := !e.bg.Value && !turnOff
		if wantFg {
			// if foreground mode, create a WatchIPNBus session
			// and use the nested config for all following operations
			// TODO(marwan-at-work): nested-config validations should happen here or previous to this point.
			watcher, err = e.lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
			if err != nil {
				return err
			}
			defer watcher.Close()
			n, err := watcher.Next()
			if err != nil {
				return err
			}
			if n.SessionID == "" {
				return errors.New("missing SessionID")
			}
			fsc := &ipn.ServeConfig{}
			mak.Set(&sc.Foreground, n.SessionID, fsc)
			sc = fsc
		}
```

Lines 532-554

```go
			return errHelpFunc(subcmd)
		}

		if err := e.lc.SetServeConfig(ctx, parentSC); err != nil {
			if local.IsPreconditionsFailedError(err) {
				fmt.Fprintln(e.stderr(), "Another client is changing the serve config; please try again.")
			}
			return err
		}

		if msg != "" {
			fmt.Fprintln(e.stdout(), msg)
		}

		if watcher != nil {
			for {
				_, err = watcher.Next()
				if err != nil {
					if errors.Is(err, io.EOF) || errors.Is(err, context.Canceled) {
						return nil
					}
					return err
				}
```

## client/local/serve.go

Primary source: https://github.com/tailscale/tailscale/blob/3caf7d9e7dcaba589cfc58beda596929733e4fea/client/local/serve.go

Full source SHA256: 5f6953d80408cf9f4805cd7a24773e06b8b36873d5f36c5587bb01578991d7c0

Lines 17-61

```go
// GetServeConfig return the current serve config.
//
// If the serve config is empty, it returns (nil, nil).
//
// API maturity: this method is not considered a stable API and is
// subject to change between releases.
func (lc *Client) GetServeConfig(ctx context.Context) (*ipn.ServeConfig, error) {
	body, h, err := lc.sendWithHeaders(ctx, "GET", "/localapi/v0/serve-config", 200, nil, nil)
	if err != nil {
		return nil, fmt.Errorf("getting serve config: %w", err)
	}
	sc, err := getServeConfigFromJSON(body)
	if err != nil {
		return nil, err
	}
	if sc == nil {
		sc = new(ipn.ServeConfig)
	}
	sc.ETag = h.Get("Etag")
	return sc, nil
}

func getServeConfigFromJSON(body []byte) (sc *ipn.ServeConfig, err error) {
	if err := json.Unmarshal(body, &sc); err != nil {
		return nil, err
	}
	return sc, nil
}

// SetServeConfig sets or replaces the serving settings.
// If config is nil, settings are cleared and serving is disabled.
func (lc *Client) SetServeConfig(ctx context.Context, config *ipn.ServeConfig) error {
	h := make(http.Header)
	if config != nil {
		h.Set("If-Match", config.ETag)
	}
	_, _, err := lc.sendWithHeaders(ctx, "POST", "/localapi/v0/serve-config", 200, jsonBody(config), h)
	if err != nil {
		return fmt.Errorf("sending serve config: %w", err)
	}
	return nil
}
```

## ipn/ipnlocal/serve.go

Primary source: https://github.com/tailscale/tailscale/blob/3caf7d9e7dcaba589cfc58beda596929733e4fea/ipn/ipnlocal/serve.go

Full source SHA256: e6c03677c4fa5ba650f73100a459d5533b0767796eab88c77d675f7e478f3c86

Lines 422-436

```go
// DeleteForegroundSession deletes a ServeConfig's foreground session
// in the LocalBackend if it exists. It also ensures check, delete, and
// set operations happen within the same mutex lock to avoid any races.
func (b *LocalBackend) DeleteForegroundSession(sessionID string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.serveConfig.Valid() || !b.serveConfig.Foreground().Contains(sessionID) {
		return nil
	}
	sc := b.serveConfig.AsStruct()
	delete(sc.Foreground, sessionID)
	return b.setServeConfigLocked(sc, "")
}

// HandleIngressTCPConn handles a TCP connection initiated by the ingressPeer
```

Lines 1758-1784

```go
	}

	// New foreground listeners must be on open ports.
	for sessionID, incomingFg := range incoming.Foreground().All() {
		if !existing.Foreground().Has(sessionID) {
			// This is a new session.
			for port := range incomingFg.TCPs() {
				if _, exists := existing.FindTCP(port); exists {
					return fmt.Errorf("listener already exists for port %d", port)
				}
			}
		}
	}

	// New background listeners cannot overwrite existing foreground listeners.
	for port := range incoming.TCP().All() {
		if _, exists := existing.FindForegroundTCP(port); exists {
			return fmt.Errorf("foreground listener already exists for port %d", port)
		}
	}

	// Incoming configuration cannot change the serve type in use by a port.
	for port, incomingHandler := range incoming.TCP().All() {
		existingHandler, exists := existing.FindTCP(port)
		if !exists {
			continue
		}
```

## ipn/ipnlocal/local.go — watcher teardown call site

Primary source: https://github.com/tailscale/tailscale/blob/3caf7d9e7dcaba589cfc58beda596929733e4fea/ipn/ipnlocal/local.go

Full source SHA256: e3f29a92e870ee23fdbecf8d1c0a0ccc1f3b7e0858785d9121224dc290ee403d

WatchNotificationsAs creates the session ID at lines 3720–3728; its sender.Run(ctx,ch) returns on the watcher request/context ending, and deferred DeleteForegroundSession removes only that session. This establishes the missing caller, not an observed live route cleanup.

```go
	// TODO(marwan-at-work): streaming background logs?
	defer b.DeleteForegroundSession(sessionID)

	sender := &rateLimitingBusSender{fn: fn}
	defer sender.close()

	if mask&ipn.NotifyRateLimit != 0 {
		sender.interval = 3 * time.Second
	}

	sender.Run(ctx, ch)
}

// appendHealthActions returns an IPN listener func that wraps the supplied IPN
```
