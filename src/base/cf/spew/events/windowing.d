﻿module cf.spew.events.windowing;
import cf.spew.events.defs;

union Windowing_Events {
	struct {
		// cursor moved and stopped moving

		///
		CursorEventAction cursorAction;
		///
		int x, y;
	}

	struct {
		// scroll

		///
		int amount;
	}

	struct {
		// close
	}

	struct {
		// window size changed

		///
		uint newWidth, newHeight;
	}

	struct {
		// window moved

		///
		int newX, newY;
	}

	struct {
		// key down + up

		////
		dchar key;
		///
		KeyModifiers keyModifiers;
		///
		SpecialKey keySpecial;
	}
}

///
enum CursorEventAction {
	/**
     * Triggered when the left mouse button is clicked when backed by a mouse.
     */
	Select,
	
	/**
     * Triggered when the right mouse button is clicked when backed by a mouse.
     */
	Alter,
	
	/**
     * Triggered when the middle mouse button is clicked when backed by a mouse.
     */
	ViewChange
}

///
enum KeyModifiers : ushort {
	///
	None = 0,
	
	///
	Control = 1 << 1,
	///
	LControl = Control | (1 << 2),
	///
	RControl = Control | (1 << 3),
	
	///
	Alt = 1 << 4,
	///
	LAlt = Alt | (1 << 5),
	///
	RAlt = Alt | (1 << 6),
	
	///
	Shift = 1 << 7,
	///
	LShift = Shift | (1 << 8),
	///
	RShift = Shift | (1 << 9),
	
	///
	Super = 1 << 10,
	///
	LSuper = Super | (1 << 11),
	///
	RSuper = Super | (1 << 12),
	
	///
	Capslock = 1 << 13,
	
	///
	Numlock = 1 << 14
}

///
enum SpecialKey {
	///
	None,
	
	///
	F1,
	///
	F2,
	///
	F3,
	///
	F4,
	///
	F5,
	///
	F6,
	///
	F7,
	///
	F8,
	///
	F9,
	///
	F10,
	///
	F11,
	///
	F12,
	
	///
	Escape,
	///
	Enter,
	///
	Backspace,
	///
	Tab,
	///
	PageUp,
	///
	PageDown,
	///
	End,
	///
	Home,
	///
	Insert,
	///
	Delete,
	///
	Pause,
	
	///
	LeftArrow, 
	///
	RightArrow,
	///
	UpArrow,
	///
	DownArrow,
	
	///
	ScrollLock
}

