//go:build !android

package omnitunnel

// Elsewhere Go reads the default route itself.
func setDefaultInterface(string) {}
