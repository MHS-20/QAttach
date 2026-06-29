package identity

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	imdsBaseURL = "http://169.254.169.254/latest"
	imdsTokenURL = imdsBaseURL + "/api/token"
	tokenTTL    = "21600" // 6 hours
	tokenHeader = "X-aws-ec2-metadata-token"
	requestTimeout = 5 * time.Second
)

// NodeIdentity holds discovered identity information for this EC2 instance.
type NodeIdentity struct {
	InstanceID string
	PrivateIP  string
	AZ         string
}

// Discover discovers instance identity via IMDSv2.
// Falls back to hostname-based ID if not running on EC2.
func Discover() (*NodeIdentity, error) {
	client := &http.Client{Timeout: requestTimeout}

	// IMDSv2 token
	token, err := getToken(client)
	if err != nil {
		return fallbackIdentity(err)
	}

	id := &NodeIdentity{}

	// instance-id
	id.InstanceID, err = getMeta(client, token, "/meta-data/instance-id")
	if err != nil {
		return fallbackIdentity(err)
	}

	// private-ipv4
	id.PrivateIP, err = getMeta(client, token, "/meta-data/local-ipv4")
	if err != nil {
		// non-fatal — use interface detection
		id.PrivateIP = detectLocalIP()
	}

	// availability-zone
	id.AZ, err = getMeta(client, token, "/meta-data/placement/availability-zone")
	if err != nil {
		// non-fatal
		id.AZ = "unknown"
	}

	return id, nil
}

func getToken(client *http.Client) (string, error) {
	req, err := http.NewRequest("PUT", imdsTokenURL, strings.NewReader(""))
	if err != nil {
		return "", err
	}
	req.Header.Set("X-aws-ec2-metadata-token-ttl-seconds", tokenTTL)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("imds token: status %d", resp.StatusCode)
	}

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
	return strings.TrimSpace(string(body)), nil
}

func getMeta(client *http.Client, token, path string) (string, error) {
	req, err := http.NewRequest("GET", imdsBaseURL+path, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set(tokenHeader, token)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("imds %s: status %d", path, resp.StatusCode)
	}

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return strings.TrimSpace(string(body)), nil
}

func fallbackIdentity(imdsErr error) (*NodeIdentity, error) {
	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "unknown"
	}
	return &NodeIdentity{
		InstanceID: hostname,
		PrivateIP:  detectLocalIP(),
		AZ:         "local",
	}, fmt.Errorf("imds unavailable, using fallback identity: %w", imdsErr)
}

func detectLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
			return ipnet.IP.String()
		}
	}
	return "127.0.0.1"
}
