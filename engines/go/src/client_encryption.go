package main

import (
	"context"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const ageChunkSize int64 = 65536
const ageSealedChunkSize int64 = ageChunkSize + 16

type clientEncryption struct {
	header, nonce, fileKey []byte
	headerLength           int64
	fileName               string
}

// Derive the plaintext name before applying destination safety and collisions.
func (ce *clientEncryption) downloadName(key string) string {
	if ce == nil {
		return key
	}
	if ce.fileName != "" {
		return ce.fileName
	}
	name := filepath.Base(strings.ReplaceAll(key, "\\", "/"))
	if stripped := strings.TrimSuffix(name, ".age"); stripped != "" {
		name = stripped
	}
	return name
}

func invalidClientEncryption() error {
	return &sidecarError{Code: "invalid_config", Message: "Invalid age-v1 client encryption configuration; exactly one file or key is required."}
}

func parseClientEncryption(params map[string]interface{}, upload bool) (*clientEncryption, error) {
	raw := params["clientEncryption"]
	if raw == nil {
		return nil, nil
	}
	v, ok := raw.(map[string]interface{})
	if !ok || v["format"] != "age-v1" {
		return nil, invalidClientEncryption()
	}
	allowed := map[string]bool{"format": true, "fileKey": true}
	if upload {
		allowed["header"] = true
		allowed["payloadNonce"] = true
	} else {
		allowed["headerLength"] = true
		allowed["fileName"] = true
	}
	for name := range v {
		if !allowed[name] {
			return nil, invalidClientEncryption()
		}
	}
	decode := func(name string) ([]byte, error) {
		text, ok := v[name].(string)
		if !ok {
			return nil, invalidClientEncryption()
		}
		b, err := base64.StdEncoding.Strict().DecodeString(text)
		if err != nil {
			return nil, invalidClientEncryption()
		}
		return b, nil
	}
	ce := &clientEncryption{}
	if rawName, present := v["fileName"]; present {
		name, ok := rawName.(string)
		if !ok || name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\\\x00") {
			return nil, invalidClientEncryption()
		}
		ce.fileName = name
	}
	var err error
	ce.fileKey, err = decode("fileKey")
	if err != nil || len(ce.fileKey) != 16 {
		return nil, invalidClientEncryption()
	}
	if upload {
		if len(asStringSlice(params["filePaths"])) != 1 {
			return nil, invalidClientEncryption()
		}
		ce.header, err = decode("header")
		if err != nil || len(ce.header) < 1 || len(ce.header) > 65536 {
			return nil, invalidClientEncryption()
		}
		ce.headerLength = int64(len(ce.header))
		ce.nonce, err = decode("payloadNonce")
		if err != nil || len(ce.nonce) != 16 {
			return nil, invalidClientEncryption()
		}
	} else {
		if len(asStringSlice(params["keys"])) != 1 {
			return nil, invalidClientEncryption()
		}
		// Accept the integer forms used by direct callers as well as JSON numbers.
		switch n := v["headerLength"].(type) {
		case int:
			ce.headerLength = int64(n)
		case int64:
			ce.headerLength = n
		case float64:
			if n < 1 || n > 65536 || math.Trunc(n) != n {
				return nil, invalidClientEncryption()
			}
			ce.headerLength = int64(n)
		default:
			return nil, invalidClientEncryption()
		}
		if ce.headerLength < 1 || ce.headerLength > 65536 {
			return nil, invalidClientEncryption()
		}
	}
	return ce, nil
}

func ageChunks(p int64) int64 {
	if p == 0 {
		return 1
	}
	return 1 + (p-1)/ageChunkSize
}
func ageObjectLength(h, p int64) (int64, error) {
	if h < 1 || h > 65536 || p < 0 || p > math.MaxInt64-h-16-16*ageChunks(p) {
		return 0, invalidClientEncryption()
	}
	return h + 16 + p + 16*ageChunks(p), nil
}
func decryptionFailed(chunk int64) error {
	return &sidecarError{Code: "decryption_failed", Message: "Client-encrypted object failed authentication or has an impossible length.", Details: map[string]interface{}{"chunk": chunk}}
}
func agePlaintextLength(h, c int64) (int64, error) {
	if h < 1 || h > 65536 || c < h+32 {
		return 0, decryptionFailed(0)
	}
	payload := c - h - 16
	chunks := 1 + (payload-1)/ageSealedChunkSize
	p := payload - 16*chunks
	if p < 0 || ageChunks(p) != chunks {
		return 0, decryptionFailed(chunks - 1)
	}
	actual, err := ageObjectLength(h, p)
	if err != nil || actual != c {
		return 0, decryptionFailed(chunks - 1)
	}
	return p, nil
}
func agePayloadCipher(key, salt []byte) (cipher.AEAD, error) {
	payloadKey := make([]byte, chacha20poly1305.KeySize)
	if _, err := io.ReadFull(hkdf.New(sha256.New, key, salt, []byte("payload")), payloadKey); err != nil {
		return nil, err
	}
	return chacha20poly1305.New(payloadKey)
}
func ageChunkNonce(index int64, final bool) []byte {
	nonce := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(nonce[3:11], uint64(index))
	if final {
		nonce[11] = 1
	}
	return nonce
}

// ReadAt maps a ciphertext range to only the source chunks it overlaps. Each
// call holds at most one plaintext chunk and its sealed form. SectionReader
// supplies seeking/replay for SDK signing and retries without buffering a part.
type ageUploadReader struct {
	source                  io.ReaderAt
	verify                  func() error
	aead                    cipher.AEAD
	prefix                  []byte
	plaintextLength, length int64
}

func newAgeUploadReader(source io.ReaderAt, verify func() error, ce *clientEncryption, p int64) (*ageUploadReader, error) {
	c, err := ageObjectLength(ce.headerLength, p)
	if err != nil {
		return nil, err
	}
	aead, err := agePayloadCipher(ce.fileKey, ce.nonce)
	if err != nil {
		return nil, err
	}
	prefix := append(append([]byte{}, ce.header...), ce.nonce...)
	return &ageUploadReader{source: source, verify: verify, aead: aead, prefix: prefix, plaintextLength: p, length: c}, nil
}
func (r *ageUploadReader) ReadAt(dst []byte, offset int64) (int, error) {
	if offset < 0 {
		return 0, fmt.Errorf("negative ciphertext offset")
	}
	if r.verify != nil {
		if err := r.verify(); err != nil {
			return 0, err
		}
	}
	if offset >= r.length {
		return 0, io.EOF
	}
	n := 0
	for len(dst) > 0 && offset < r.length {
		var data []byte
		var local int64
		if offset < int64(len(r.prefix)) {
			data = r.prefix
			local = offset
		} else {
			relative := offset - int64(len(r.prefix))
			index := relative / ageSealedChunkSize
			local = relative % ageSealedChunkSize
			plain := make([]byte, min(ageChunkSize, r.plaintextLength-index*ageChunkSize))
			if len(plain) > 0 {
				if _, err := r.source.ReadAt(plain, index*ageChunkSize); err != nil {
					return n, err
				}
			}
			data = r.aead.Seal(nil, ageChunkNonce(index, index == ageChunks(r.plaintextLength)-1), plain, nil)
		}
		copied := copy(dst, data[local:])
		dst = dst[copied:]
		n += copied
		offset += int64(copied)
	}
	if r.verify != nil {
		if err := r.verify(); err != nil {
			return n, err
		}
	}
	if len(dst) > 0 {
		return n, io.EOF
	}
	return n, nil
}

// A bounded in-memory range is never the staged plaintext file: retries may
// replace unauthenticated bytes here, but only AEAD.Open output reaches disk.
type cipherRangeBuffer []byte

func (b cipherRangeBuffer) WriteAt(p []byte, offset int64) (int, error) {
	if offset < 0 || offset > int64(len(b)) {
		return 0, io.ErrShortWrite
	}
	n := copy(b[offset:], p)
	if n != len(p) {
		return n, io.ErrShortWrite
	}
	return n, nil
}

type ageRangeOpener func(context.Context, int64, int64) (io.ReadCloser, error)

func downloadAgePayload(ctx context.Context, target *os.File, ce *clientEncryption, size int64, workers, attempts int, open ageRangeOpener, progress func(int64, bool)) error {
	p, err := agePlaintextLength(ce.headerLength, size)
	if err != nil {
		return err
	}
	fetch := func(ctx context.Context, start, length int64) ([]byte, error) {
		buffer := make(cipherRangeBuffer, length)
		_, err := downloadRangeWithRetry(ctx, buffer, 0, length, attempts, func() (io.ReadCloser, error) { return open(ctx, start, length) })
		return buffer, err
	}
	nonce, err := fetch(ctx, ce.headerLength, 16)
	if err != nil {
		return err
	}
	aead, err := agePayloadCipher(ce.fileKey, nonce)
	if err != nil {
		return err
	}
	if err = target.Truncate(p); err != nil {
		return err
	}
	// Progress measures stored-object bytes; the host already consumed the header.
	progress(ce.headerLength+16, false)
	return parallelParts(ctx, int(ageChunks(p)), workers, func(ctx context.Context, index int) error {
		i := int64(index)
		length := min(ageChunkSize, p-i*ageChunkSize) + 16
		sealed, err := fetch(ctx, ce.headerLength+16+i*ageSealedChunkSize, length)
		if err != nil {
			return err
		}
		plain, err := aead.Open(nil, ageChunkNonce(i, i == ageChunks(p)-1), sealed, nil)
		if err != nil {
			return decryptionFailed(i)
		}
		if len(plain) > 0 {
			n, err := target.WriteAt(plain, i*ageChunkSize)
			if err != nil {
				return err
			}
			if n != len(plain) {
				return io.ErrShortWrite
			}
		}
		progress(length, true)
		return nil
	})
}

func clientEncryptionSecrets(params map[string]interface{}) []string {
	raw, ok := params["clientEncryption"].(map[string]interface{})
	if !ok {
		return nil
	}
	// fileName is redacted as a field (encryptionSecretField) but its value is
	// not scrubbed from text: it is an ordinary word and the published
	// destination path legitimately contains it.
	key, ok := raw["fileKey"].(string)
	if !ok {
		return nil
	}
	secrets := []string{key}
	if decoded, err := base64.StdEncoding.Strict().DecodeString(key); err == nil {
		secrets = append(secrets, base64.StdEncoding.EncodeToString(decoded))
	}
	return secrets
}
func protectClientEncryptionResult(params map[string]interface{}, result *map[string]interface{}, err *error) {
	secrets := clientEncryptionSecrets(params)
	if len(secrets) == 0 {
		return
	}
	if *err != nil {
		*err = &encryptionFailure{cause: *err, secrets: secrets}
	}
	if *result != nil {
		*result = redactEncryptionValues(redactEncryptionFields(*result), secrets).(map[string]interface{})
	}
}
