// Link mode: the toy's own WiFi network, so the phone can write the card in
// place.
//
// The card is normally the transport — you take it out, put it in a reader and
// Bookie Studio writes it. Link mode is the same job without the tweezers: the
// ESP32 raises a WPA2 access point, serves a small HTTP API over the SD card at
// http://192.168.4.1, and the app drives it through exactly the same calls it
// makes against a reader (list, read, write, delete).
//
// It is never on by itself. Hold the language button and press volume up, or type
// `link` in the serial console; it drops again on any button, on `link off`, or
// after LINK_IDLE_MS with nothing asking for anything. While it is up, NFC
// polling and idle sleep are suspended — the toy is a card reader, not a toy.
#pragma once

#include <Arduino.h>

namespace toylink {

bool active();

// Brings up the access point and the server. Stops playback first: WiFi wants
// the heap, and nobody writes a card while a story is running.
bool start();

// Tears both down and rescans the card, so anything the phone just wrote is
// live without a reboot.
void stop();

// Call from loop(): honours the idle timeout and a `done` from the app.
void poll();

// A phone has joined the toy's network. Joined, not necessarily talking yet —
// but it is the moment the toy can stop sounding its pairing blip.
bool phoneConnected();

// "Bookie-1A2B" — what the phone is looking for. Empty until start().
const char *ssid();

}  // namespace toylink
