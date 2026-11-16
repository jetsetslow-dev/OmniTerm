//go:build !omniterm_access_fixture

package omnitunnel

import "net/http"

func accessTransport() *http.Transport { return accessDefaultTransport() }
