package netlink

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"sync"
	"syscall"
	"unsafe"

	"github.com/polarity/qattach/pkg/protocol"
)

// Handler receives messages from the kernel module.
type Handler interface {
	HandleLockRequest(req protocol.LockRequest)
	HandleLockRelease(req protocol.LockRelease)
	HandleUnmount()
	HandleMountRequest(req protocol.MountRequest)
}

// Server listens on a custom Netlink family for messages from lock_etcd.ko.
type Server struct {
	fd      int
	handler Handler
	wg      sync.WaitGroup
	done    chan struct{}
}

// ListenRaw binds directly to the custom Netlink family.
// The kernel module sends to PID 0 (kernel); one agent per node binds here.
func ListenRaw() (*Server, error) {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW, protocol.LetcdNetlinkFamily)
	if err != nil {
		return nil, fmt.Errorf("netlink socket: %w", err)
	}

	sa := &syscall.SockaddrNetlink{
		Family: syscall.AF_NETLINK,
		Groups: 0,
	}
	if err := syscall.Bind(fd, sa); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("netlink bind: %w", err)
	}

	return &Server{
		fd:   fd,
		done: make(chan struct{}),
	}, nil
}

// SetHandler sets the message handler.
func (s *Server) SetHandler(h Handler) {
	s.handler = h
}

// Serve starts the receive loop. Blocks until Stop is called.
func (s *Server) Serve() error {
	buf := make([]byte, protocol.LetcdMaxPayload+syscall.NLMSG_HDRLEN)

	for {
		select {
		case <-s.done:
			return nil
		default:
		}

		n, from, err := syscall.Recvfrom(s.fd, buf, 0)
		if err != nil {
			log.Printf("netlink recv error: %v", err)
			select {
			case <-s.done:
				return nil
			default:
				return fmt.Errorf("netlink recv: %w", err)
			}
		}

		log.Printf("netlink recv: n=%d from=%v", n, from)

		if n < syscall.NLMSG_HDRLEN {
			continue
		}

		// Parse netlink header
		hdr := (*syscall.NlMsghdr)(unsafe.Pointer(&buf[0]))
		if hdr.Len == 0 || int(hdr.Len) > n {
			continue
		}

		payload := buf[syscall.NLMSG_HDRLEN:hdr.Len]
		s.dispatch(hdr.Type, payload)
	}
}

// Stop shuts down the server.
func (s *Server) Stop() {
	select {
	case <-s.done:
		return
	default:
		close(s.done)
		syscall.Close(s.fd)
	}
}

func (s *Server) dispatch(msgType uint16, payload []byte) {
	if s.handler == nil {
		log.Printf("netlink dispatch: no handler set, msgType=%d len=%d", msgType, len(payload))
		return
	}

	log.Printf("netlink dispatch: msgType=%d len=%d", msgType, len(payload))

	switch uint32(msgType) {
	case protocol.MsgLockReq:
		var req protocol.LockRequest
		if decodeLE(payload, &req) {
			s.handler.HandleLockRequest(req)
		}

	case protocol.MsgLockRel:
		var req protocol.LockRelease
		if decodeLE(payload, &req) {
			s.handler.HandleLockRelease(req)
		}

	case protocol.MsgUnmount:
		s.handler.HandleUnmount()

	case protocol.MsgMountReq:
		var req protocol.MountRequest
		if decodeLE(payload, &req) {
			s.handler.HandleMountRequest(req)
		}
	}
}

// SendLockGrant sends a lock grant response to the kernel module.
func (s *Server) SendLockGrant(grant protocol.LockGrant) error {
	return s.sendMsg(protocol.MsgLockGrant, grant)
}

// SendLockDeny sends a lock denial to the kernel module.
func (s *Server) SendLockDeny(deny protocol.LockDeny) error {
	return s.sendMsg(protocol.MsgLockDeny, deny)
}

// SendLockWait sends a lock wait notification to the kernel module.
func (s *Server) SendLockWait(wait protocol.LockWait) error {
	return s.sendMsg(protocol.MsgLockWait, wait)
}

// SendBast sends a BAST notification to the kernel module.
func (s *Server) SendBast(bast protocol.BastNotification) error {
	return s.sendMsg(protocol.MsgBast, bast)
}

// SendRecoveryOk signals the kernel that journal recovery is safe.
func (s *Server) SendRecoveryOk(ok protocol.RecoveryOk) error {
	return s.sendMsg(protocol.MsgRecoveryOk, ok)
}

// SendMountResponse sends the mount response with assigned journal ID.
func (s *Server) SendMountResponse(resp protocol.MountResponse) error {
	return s.sendMsg(protocol.MsgMountResp, resp)
}

// SendRegister sends a REGISTER message to the kernel so it learns the
// agent's PID for subsequent unicast replies.
func (s *Server) SendRegister() error {
	var zero [4]byte
	return s.sendMsg(protocol.MsgRegister, zero)
}

func (s *Server) sendMsg(msgType uint32, v interface{}) error {
	var body bytes.Buffer

	// Message type prefix
	if err := binary.Write(&body, binary.LittleEndian, msgType); err != nil {
		return err
	}

	// Payload
	if err := binary.Write(&body, binary.LittleEndian, v); err != nil {
		return err
	}

	payload := body.Bytes()

	// Build netlink message — the kernel reads nlmsg_pid as the sender.
	// We must set it to our own PID so the kernel can unicast replies back.
	nlh := syscall.NlMsghdr{
		Len:   uint32(syscall.NLMSG_HDRLEN + len(payload)),
		Type:  uint16(msgType),
		Flags: 0,
		Seq:   0,
		Pid:   uint32(os.Getpid()),
	}

	buf := make([]byte, nlh.Len)

	// Write header
	*(*syscall.NlMsghdr)(unsafe.Pointer(&buf[0])) = nlh

	// Write payload
	copy(buf[syscall.NLMSG_HDRLEN:], payload)

	sa := &syscall.SockaddrNetlink{
		Family: syscall.AF_NETLINK,
		Pid:    0, // to kernel
	}

	err := syscall.Sendto(s.fd, buf, 0, sa)
	if err != nil {
		log.Printf("netlink send error (type=%d plen=%d buflen=%d): %v",
			msgType, len(payload), len(buf), err)
	}
	return err
}

func decodeLE(data []byte, v interface{}) bool {
	return binary.Read(bytes.NewReader(data), binary.LittleEndian, v) == nil
}
