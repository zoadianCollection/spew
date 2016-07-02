﻿module cf.spew.event_loop.wells.winapi;
version(Windows):

import cf.spew.event_loop.defs;
import cf.spew.event_loop.known_implementations;
import cf.spew.events.defs;
import cf.spew.events.winapi;
import std.experimental.allocator : IAllocator, make;
import core.sys.windows.windows : LRESULT, WPARAM, LPARAM, HWND;
import core.time : Duration;

struct EventLoopAlterationCallbacks {
	bool delegate(bool logoff, bool force, bool closeapp) nothrow canShutdown;
	void delegate(bool isShuttingDown, bool logoff, bool force, bool closeapp) nothrow systemShutdownResult;
	bool delegate(LPARAM lParam) nothrow modifySetCursor;
}

final class WinAPI_EventLoop_Source : EventLoopSource {
	@property {
		bool onMainThread() { return true; }
		bool onAdditionalThreads() { return true; }

		EventSource identifier() { return EventSources.WinAPI; }
	}

	EventLoopSourceRetriever nextEventGenerator(IAllocator alloc) {
		return alloc.make!WinAPI_EventLoop_SourceRetriever;
	}
}


final class WinAPI_EventLoop_SourceRetriever : EventLoopSourceRetriever {
	private {
		import core.sys.windows.windows : DWORD, MSG, INFINITE;

		DWORD msTimeout = INFINITE;
		MSG msg;
		bool needToWait;
	}

	bool nextEvent(ref Event event) {
		import core.sys.windows.windows : MsgWaitForMultipleObjectsEx,
			QS_ALLINPUT, WAIT_TIMEOUT,
			MWMO_ALERTABLE, MWMO_INPUTAVAILABLE,
			PeekMessageW, PM_REMOVE,
			TranslateMessage, DispatchMessageW;

		if (needToWait) {
			MsgWaitForMultipleObjectsEx(
				cast(DWORD)0, null,
				msTimeout, QS_ALLINPUT,
				// MWMO_ALERTABLE: Wakes up to execute overlapped hEvent (i/o completion)
				// MWMO_INPUTAVAILABLE: Processes key/mouse input to avoid window ghosting
				MWMO_ALERTABLE | MWMO_INPUTAVAILABLE);
			needToWait = false;
		}

		event.source = EventSources.WinAPI;
		event.type = WinAPI_Events_Types.Unknown;
		event.winapi.raw = msg;

		_event = &event;
		scope(exit)
			_event = null;

		for (;;) {
			if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) == 0) {
				needToWait = true;
				return false;
			} else {
				if (msg.hwnd !is null && shouldTranslate)
					TranslateMessage(&msg);

				event.winapi.raw = msg;
				DispatchMessageW(&msg);

				if (event.type == WinAPI_Events_Types.Unknown)
					continue;
			}
		}
	}

	void handledEvent(ref Event event) {}

	void unhandledEvent(ref Event event) {
		import core.sys.windows.windows : DefWindowProc;

		// we purposely desired to use raw so here we go
		if (event.type == WinAPI_Events_Types.Raw)
			DefWindowProc(msg.hwnd, msg.message, msg.wParam, msg.lParam);
	}

	void hintTimeout(Duration timeout) {
		msTimeout = cast(DWORD)timeout.total!"msecs";

		if (msTimeout == 0)
			msTimeout = INFINITE;
	}

	bool shouldTranslate() {
		import core.sys.windows.windows : LOWORD, HIWORD,
			WM_SYSKEYDOWN, WM_SYSKEYUP, WM_KEYDOWN, WM_KEYUP, WM_CHAR,
			VK_NUMPAD0, VK_NUMPAD9, VK_ADD, VK_SUBTRACT, VK_MULTIPLY,
			VK_DIVIDE, VK_DECIMAL, VK_OEM_2, VK_OEM_PERIOD, VK_OEM_COMMA;
		
		auto id = LOWORD(msg.message);
		
		switch(id) {
			case WM_SYSKEYDOWN: case WM_SYSKEYUP:
			case WM_KEYDOWN: case WM_KEYUP:
			case WM_CHAR:
				break;
			default:
				return false;
		}
		
		switch(msg.wParam) {
			case VK_NUMPAD0: .. case VK_NUMPAD9:
				bool haveAlt = (msg.lParam & (1 << 29)) == 1 << 29;
				return haveAlt;
				
			case VK_ADD: case VK_SUBTRACT:
			case VK_MULTIPLY: case VK_DIVIDE:
			case VK_DECIMAL:
			case VK_OEM_2:
			case VK_OEM_PERIOD:
			case VK_OEM_COMMA:
				return false;
			default:
				return true;
		}
	}
}

private {
	/**
	 * Thread local, non issue since only one event loop ever runs
	 */
	Event* _event;

	enum {
		ENDSESSION_CRITICAL = 0x40000000,
		ENDSESSION_CLOSEAPP = 0x00000001
	}
}

/**
 * Use this callback when registering a WinAPI window to allow auto hooking into any
 *  WinAPI_EventLoop_SourceRetriever event retriever that may exist.
 */
extern(Windows)
LRESULT callbackWindowHandler(HWND hwnd, uint uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	import cf.spew.events.windowing;
	import core.sys.windows.windows;

	if (_event is null) // ERROR
		return DefWindowProcW(hwnd, uMsg, wParam, lParam);

	EventLoopAlterationCallbacks* callbacks = cast(EventLoopAlterationCallbacks*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);

	_event.wellData1Ptr = hwnd;

	switch(uMsg) {
		case WM_NULL:
			// do nothing
			return 0;

		case WM_CREATE:
			_event.type = WinAPI_Events_Types.Window_Create;
			_event.winapi.window_create = *cast(CREATESTRUCT*)lParam;
			// we do not provide a way to stop creation at this point.
			return 0;

		case WM_DESTROY:
			_event.type = WinAPI_Events_Types.Window_Destroy;
			// if you use SetClipboardViewer don't forget to
			// call ChangeClipboardChain(hwnd, otherHwnd) here
			return 0;

		case WM_MOVE:
			_event.type = Windowing_Events_Types.Window_Moved;
			_event.windowing.newX = LOWORD(lParam);
			_event.windowing.newY = HIWORD(lParam);
			return 0;

		case WM_SIZE:
			_event.type = Windowing_Events_Types.Window_Moved;
			_event.wellData2Value = wParam;

			_event.windowing.newWidth = LOWORD(lParam);
			_event.windowing.newHeight = HIWORD(lParam);
			return 0;

		case WM_ACTIVATE:
			_event.type = Windowing_Events_Types.Window_Focused;
			_event.wellData2Value = wParam;
			_event.wellData3Ptr = SetFocus(hwnd);
			return 0;

		case WM_SETFOCUS:
			_event.type = WinAPI_Events_Types.Window_GainedKeyboardFocus;
			_event.winapi.lostFocusWindow = cast(HWND)wParam;
			// if you need a caret display it now
			return 0;

		case WM_KILLFOCUS:
			_event.type = WinAPI_Events_Types.Window_LostKeyboardFocus;
			_event.winapi.gainedFocusWindow = cast(HWND)wParam;
			// if you display a caret destroy it!
			return 0;

		case WM_ENABLE:
			if (wParam == TRUE)
				_event.type = WinAPI_Events_Types.Window_Enable;
			else
				_event.type = WinAPI_Events_Types.Window_Disable;
			return 0;

		case WM_SETREDRAW:
			_event.type = WinAPI_Events_Types.Window_SetRedraw;
			_event.winapi.redrawState = wParam == TRUE;
			return 0;

		case WM_PAINT:
			_event.type = WinAPI_Events_Types.Window_Paint;
			return 0;

		case WM_CLOSE:
			_event.type = Windowing_Events_Types.Window_RequestClose;
			// call DestroyWindow if you do wish to close the window
			return 0;

		case WM_QUERYENDSESSION:
			if (callbacks.canShutdown !is null) {
				if (!callbacks.canShutdown(
						(lParam & ENDSESSION_LOGOFF) == ENDSESSION_LOGOFF,
						(lParam & ENDSESSION_CRITICAL) == ENDSESSION_CRITICAL,
						(lParam & ENDSESSION_CLOSEAPP) == ENDSESSION_CLOSEAPP)) {
					return FALSE;
				}
			}

			return TRUE;

		case WM_ENDSESSION:
			if (callbacks.systemShutdownResult !is null) {
				callbacks.systemShutdownResult(wParam == TRUE,
					(lParam & ENDSESSION_LOGOFF) == ENDSESSION_LOGOFF,
					(lParam & ENDSESSION_CRITICAL) == ENDSESSION_CRITICAL,
					(lParam & ENDSESSION_CLOSEAPP) == ENDSESSION_CLOSEAPP);
			}
			return 0;

		case WM_QUIT:
			_event.type = WinAPI_Events_Types.Window_Quit;
			_event.wellData2Value = wParam;
			// this is a hint that you probably want to on call to
			// PostQuitMessage(wParam)
			return 0;

		case WM_ERASEBKGND:
			_event.type = WinAPI_Events_Types.Raw;
			// _event.winapi.raw has already been set
			// either somebody handles this or not,
			//  if not no worries, DefWindowProcW
			//  will make sure its handled, of course
			//  if you don't set hbrBackground on the
			//  window class its your own damn fault
			//  that things will get awfully corrupt.
			return -1;

		case WM_SYSCOLORCHANGE:
			_event.type = WinAPI_Events_Types.Window_SystemColorsChanged;
			return 0;

		//case WM_SYSTEMERROR:
		//case WM_CTLCOLOR:
		case WM_DEVMODECHANGE:
			import std.utf : byChar, codeLength;

			_event.type = WinAPI_Events_Types.Window_DevModeChanged;
			_event.wellData2Value = lParam;
			// that value may not live for very long...
			// well ok maybe till the next event handled *shrug*
			return 0;

		case WM_SETCURSOR:
			if (callbacks.modifySetCursor !is null) {
				if (callbacks.modifySetCursor(lParam)) {
					_event.type = WinAPI_Events_Types.Window_SetCursor;
					_event.wellData2Value = lParam;

					return TRUE;
				}
			}
			return FALSE;

		case WM_ENTERSIZEMOVE:
			_event.type = WinAPI_Events_Types.Window_EnterSizeMove;
			return 0;

		case WM_EXITSIZEMOVE:
			_event.type = WinAPI_Events_Types.Window_ExitSizeMove;
			return 0;

			//case WM_MOUSEFIRST: same as WM_MOUSEMOVE
		case WM_MOUSEMOVE:
			_event.type = Windowing_Events_Types.Window_CursorMoved;
			_event.wellData2Value = wParam;
			_event.wellData3Value = lParam;
			_event.windowing.newX = LOWORD(lParam);
			_event.windowing.newY = HIWORD(lParam);
			return 0;

		case WM_LBUTTONDOWN:
		case WM_LBUTTONUP:
		case WM_LBUTTONDBLCLK:
		case WM_RBUTTONDOWN:
		case WM_RBUTTONUP:
		case WM_RBUTTONDBLCLK:
		case WM_MBUTTONDOWN:
		case WM_MBUTTONUP:
		case WM_MBUTTONDBLCLK:
		case WM_MOUSEWHEEL:

		case WM_FONTCHANGE:
		case WM_TIMECHANGE:
		case WM_CANCELMODE:
		case WM_MOUSEACTIVATE:
		case WM_CHILDACTIVATE:
		case WM_QUEUESYNC:
		case WM_GETMINMAXINFO:
		case WM_PAINTICON:
		case WM_ICONERASEBKGND:
		case WM_NEXTDLGCTL:
		case WM_SPOOLERSTATUS:
		case WM_DRAWITEM:
		case WM_MEASUREITEM:
		case WM_DELETEITEM:
		case WM_VKEYTOITEM:
		case WM_CHARTOITEM:
			
		case WM_SETFONT:
		case WM_GETFONT:
		case WM_SETHOTKEY:
		case WM_GETHOTKEY:
		case WM_QUERYDRAGICON:
		case WM_COMPAREITEM:
		case WM_COMPACTING:
		case WM_WINDOWPOSCHANGING:
		case WM_WINDOWPOSCHANGED:
		case WM_POWER:
		case WM_COPYDATA:
		case WM_CANCELJOURNAL:
		case WM_NOTIFY:
		case WM_INPUTLANGCHANGEREQUEST:
		case WM_INPUTLANGCHANGE:
		case WM_TCARD:
		case WM_HELP:
		case WM_USERCHANGED:
		case WM_NOTIFYFORMAT:
		case WM_CONTEXTMENU:
		case WM_STYLECHANGING:
		case WM_STYLECHANGED:
		case WM_DISPLAYCHANGE:
		case WM_GETICON:
		case WM_SETICON:
			
		case WM_NCCREATE:
		case WM_NCDESTROY:
		case WM_NCCALCSIZE:
		case WM_NCHITTEST:
		case WM_NCPAINT:
		case WM_NCACTIVATE:
		case WM_GETDLGCODE:
		case WM_NCMOUSEMOVE:
		case WM_NCLBUTTONDOWN:
		case WM_NCLBUTTONUP:
		case WM_NCLBUTTONDBLCLK:
		case WM_NCRBUTTONDOWN:
		case WM_NCRBUTTONUP:
		case WM_NCRBUTTONDBLCLK:
		case WM_NCMBUTTONDOWN:
		case WM_NCMBUTTONUP:
		case WM_NCMBUTTONDBLCLK:
			
		//case WM_KEYFIRST: same as WM_KEYDOWN
		case WM_KEYDOWN:
		case WM_KEYUP:
		case WM_CHAR:
		case WM_DEADCHAR:
		case WM_SYSKEYDOWN:
		case WM_SYSKEYUP:
		case WM_SYSCHAR:
		case WM_SYSDEADCHAR:
		case WM_KEYLAST:
			
		case WM_IME_STARTCOMPOSITION:
		case WM_IME_ENDCOMPOSITION:
		case WM_IME_COMPOSITION:
		//case WM_IME_KEYLAST: same as WM_IME_COMPOSITION
			
		case WM_INITDIALOG:
		case WM_COMMAND:
		case WM_SYSCOMMAND:
		case WM_TIMER:
		case WM_HSCROLL:
		case WM_VSCROLL:
		case WM_INITMENU:
		case WM_INITMENUPOPUP:
		case WM_MENUSELECT:
		case WM_MENUCHAR:
		case WM_ENTERIDLE:
			
		case WM_CTLCOLORMSGBOX:
		case WM_CTLCOLOREDIT:
		case WM_CTLCOLORLISTBOX:
		case WM_CTLCOLORBTN:
		case WM_CTLCOLORDLG:
		case WM_CTLCOLORSCROLLBAR:
		case WM_CTLCOLORSTATIC:


			
		case WM_PARENTNOTIFY:
		case WM_ENTERMENULOOP:
		case WM_EXITMENULOOP:
		case WM_NEXTMENU:
		case WM_SIZING:
		case WM_CAPTURECHANGED:
		case WM_MOVING:
		case WM_POWERBROADCAST:
		case WM_DEVICECHANGE:
			
		case WM_MDICREATE:
		case WM_MDIDESTROY:
		case WM_MDIACTIVATE:
		case WM_MDIRESTORE:
		case WM_MDINEXT:
		case WM_MDIMAXIMIZE:
		case WM_MDITILE:
		case WM_MDICASCADE:
		case WM_MDIICONARRANGE:
		case WM_MDIGETACTIVE:
		case WM_MDISETMENU:

		case WM_DROPFILES:
		case WM_MDIREFRESHMENU:
			
		case WM_IME_SETCONTEXT:
		case WM_IME_NOTIFY:
		case WM_IME_CONTROL:
		case WM_IME_COMPOSITIONFULL:
		case WM_IME_SELECT:
		case WM_IME_CHAR:
		case WM_IME_KEYDOWN:
		case WM_IME_KEYUP:
			
		case WM_MOUSEHOVER:
		case WM_NCMOUSELEAVE:
		case WM_MOUSELEAVE:
			
		case WM_CUT:
		case WM_COPY:
		case WM_PASTE:
		case WM_CLEAR:
		case WM_UNDO:
			
		case WM_RENDERFORMAT:
		case WM_RENDERALLFORMATS:
		case WM_DESTROYCLIPBOARD:
		case WM_DRAWCLIPBOARD:
		case WM_PAINTCLIPBOARD:
		case WM_VSCROLLCLIPBOARD:
		case WM_SIZECLIPBOARD:
		case WM_ASKCBFORMATNAME:
		case WM_CHANGECBCHAIN:
		case WM_HSCROLLCLIPBOARD:
		case WM_QUERYNEWPALETTE:
		case WM_PALETTEISCHANGING:
		case WM_PALETTECHANGED:
			
		case WM_HOTKEY:
		case WM_PRINT:
		case WM_PRINTCLIENT:
			
		case WM_HANDHELDFIRST:
		case WM_HANDHELDLAST:
		case WM_PENWINFIRST:
		case WM_PENWINLAST:
		//case WM_COALESCE_FIRST:
		//case WM_COALESCE_LAST:
		// case WM_DDE_FIRST: same as WM_DDE_INITIATE
		case WM_DDE_INITIATE:
		case WM_DDE_TERMINATE:
		case WM_DDE_ADVISE:
		case WM_DDE_UNADVISE:
		case WM_DDE_ACK:
		case WM_DDE_DATA:
		case WM_DDE_REQUEST:
		case WM_DDE_POKE:
		case WM_DDE_EXECUTE:
		// case WM_DDE_LAST: same as WM_DDE_EXECUTE
			
		case WM_USER:
		case WM_APP:
			break;

		case WM_QUERYOPEN:
			// boring, nothing to do

		case WM_SETTEXT:
		case WM_GETTEXT:
		case WM_GETTEXTLENGTH:
		case WM_SHOWWINDOW:
		
		case WM_WININICHANGE:
		//case WM_SETTINGCHANGE: same as WM_WININICHANGE
		case WM_ACTIVATEAPP:

			// use the default behaviour, too complex to override
		default:
			return DefWindowProcW(hwnd, uMsg, wParam, lParam);
	}

	assert(0);
}