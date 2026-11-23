//go:build windows

package main

import (
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

var (
	user32               = syscall.NewLazyDLL("user32.dll")
	kernel32             = syscall.NewLazyDLL("kernel32.dll")
	procMessageBoxW      = user32.NewProc("MessageBoxW")
	procCreateWindowExW  = user32.NewProc("CreateWindowExW")
	procDefWindowProcW   = user32.NewProc("DefWindowProcW")
	procRegisterClassExW = user32.NewProc("RegisterClassExW")
	procGetMessageW      = user32.NewProc("GetMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessageW = user32.NewProc("DispatchMessageW")
	procPostQuitMessage  = user32.NewProc("PostQuitMessage")
	procPostMessageW     = user32.NewProc("PostMessageW")
	procDestroyWindow    = user32.NewProc("DestroyWindow")
	procShowWindow       = user32.NewProc("ShowWindow")
	procUpdateWindow     = user32.NewProc("UpdateWindow")
	procSetWindowTextW   = user32.NewProc("SetWindowTextW")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	procGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")
)

const (
	mbOK           = 0x00000000
	mbIconError    = 0x00000010
	wsCaption      = 0x00C00000
	wsBorder       = 0x00800000
	wsVisible      = 0x10000000
	wsChild        = 0x40000000
	wsExTopmost    = 0x00000008
	wsExToolWindow = 0x00000080
	ssCenter       = 0x00000001
	swShow         = 5
	wmDestroy      = 0x0002
	wmClose        = 0x0010
	smCxScreen     = 0
	smCyScreen     = 1
	colorWindow    = 5
)

type wndClassExW struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type point struct{ x, y int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

func utf16Ptr(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func showError(title, message string) {
	procMessageBoxW.Call(
		0,
		uintptr(unsafe.Pointer(utf16Ptr(message))),
		uintptr(unsafe.Pointer(utf16Ptr(title))),
		mbOK|mbIconError,
	)
}

func startSplash(version string) (func(done, total int), func()) {
	var (
		mu       sync.Mutex
		hwnd     uintptr
		labelHwnd uintptr
		closed   bool
		lastPct  = -1
	)
	ready := make(chan struct{})
	doneCh := make(chan struct{})

	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer close(doneCh)

		hInst, _, _ := procGetModuleHandleW.Call(0)
		className := utf16Ptr("ODBPortableSplashWnd")
		wndProc := syscall.NewCallback(func(h uintptr, m uint32, wp, lp uintptr) uintptr {
			switch m {
			case wmClose:
				procDestroyWindow.Call(h)
				return 0
			case wmDestroy:
				procPostQuitMessage.Call(0)
				return 0
			default:
				ret, _, _ := procDefWindowProcW.Call(h, uintptr(m), wp, lp)
				return ret
			}
		})
		wc := wndClassExW{
			cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
			lpfnWndProc:   wndProc,
			hInstance:     hInst,
			hbrBackground: colorWindow + 1,
			lpszClassName: className,
		}
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

		width, height := int32(420), int32(110)
		sw, _, _ := procGetSystemMetrics.Call(smCxScreen)
		sh, _, _ := procGetSystemMetrics.Call(smCyScreen)
		x := (int32(sw) - width) / 2
		y := (int32(sh) - height) / 2

		w, _, _ := procCreateWindowExW.Call(
			wsExTopmost|wsExToolWindow,
			uintptr(unsafe.Pointer(className)),
			uintptr(unsafe.Pointer(utf16Ptr("Object Data Browser"))),
			wsCaption|wsBorder,
			uintptr(x), uintptr(y), uintptr(width), uintptr(height),
			0, 0, hInst, 0,
		)
		var lbl uintptr
		if w != 0 {
			initial := fmt.Sprintf("Preparing Object Data Browser %s portable runtime...", version)
			lbl, _, _ = procCreateWindowExW.Call(
				0,
				uintptr(unsafe.Pointer(utf16Ptr("STATIC"))),
				uintptr(unsafe.Pointer(utf16Ptr(initial))),
				wsChild|wsVisible|ssCenter,
				16, 26, uintptr(width-40), 42,
				w, 0, hInst, 0,
			)
			procShowWindow.Call(w, swShow)
			procUpdateWindow.Call(w)
		}

		mu.Lock()
		hwnd = w
		labelHwnd = lbl
		wasClosed := closed
		mu.Unlock()
		close(ready)

		if w == 0 {
			return
		}
		if wasClosed {
			procPostMessageW.Call(w, wmClose, 0, 0)
		}

		var m msg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 {
				break
			}
			procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
			procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()

	<-ready

	update := func(done, total int) {
		if total <= 0 {
			return
		}
		pct := (done * 100) / total
		mu.Lock()
		if closed || labelHwnd == 0 || pct == lastPct {
			mu.Unlock()
			return
		}
		lastPct = pct
		lbl := labelHwnd
		mu.Unlock()
		text := fmt.Sprintf("Extracting Object Data Browser %s portable runtime (%d%%)...", version, pct)
		procSetWindowTextW.Call(lbl, uintptr(unsafe.Pointer(utf16Ptr(text))))
	}

	closeSplash := func() {
		mu.Lock()
		if closed {
			mu.Unlock()
			return
		}
		closed = true
		w := hwnd
		mu.Unlock()
		if w != 0 {
			procPostMessageW.Call(w, wmClose, 0, 0)
		}
		<-doneCh
	}

	return update, closeSplash
}
