package accessfake

import (
	"net/http/httptest"
	"testing"
)

func TestContractRejectionCases(t *testing.T) {
	for _, tc := range []struct {
		host, id, secret, path string
		status                 int
	}{
		{"ssh.access.test", "", "", "/", 403},
		{"ssh.access.test", "fixture-id", "wrong", "/", 403},
		{"ssh.access.test", "wrong", "fixture-secret", "/", 403},
		{"reject.access.test", "fixture-id", "fixture-secret", "/", 403},
		{"login.access.test", "fixture-id", "fixture-secret", "/", 302},
		{"ordinary.access.test", "fixture-id", "fixture-secret", "/", 200},
		{"unknown.access.test", "fixture-id", "fixture-secret", "/", 404},
		{"ssh.access.test", "fixture-id", "fixture-secret", "/other", 400},
	} {
		t.Run(tc.host+tc.id+tc.path, func(t *testing.T) {
			req := httptest.NewRequest("GET", "https://"+tc.host+tc.path, nil)
			req.Header.Set("CF-Access-Client-Id", tc.id)
			req.Header.Set("CF-Access-Client-Secret", tc.secret)
			out := httptest.NewRecorder()
			Handler("127.0.0.1:1", "fixture-id", "fixture-secret", Idle)(out, req)
			if out.Code != tc.status {
				t.Fatalf("got %d, want %d", out.Code, tc.status)
			}
			if tc.status == 302 && out.Header().Get("Location") != "https://login.access.test/cdn-cgi/access/login/ssh.access.test" {
				t.Fatal("wrong login path")
			}
		})
	}
}
