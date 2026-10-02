#include <Arduino.h>

// GPIO36 (VP) sits next to them on ADC1 and is left alone here; it only serves
// as "some other channel" to read in between.
constexpr int PINS[] = {34, 35};
constexpr int SAMPLES = 64;

struct Stats { int mean, lo, hi; };

static Stats sample(int pin) {
  long sum = 0; int lo = 9999, hi = 0;
  for (int i = 0; i < SAMPLES; i++) {
    int mv = analogReadMilliVolts(pin);
    sum += mv; lo = min(lo, mv); hi = max(hi, mv);
  }
  return {int(sum / SAMPLES), lo, hi};
}

void setup() {
  Serial.begin(115200);
  delay(500);
  for (int p : PINS) analogSetPinAttenuation(p, ADC_11db);
  Serial.println("\nadc-probe: GPIO34 / GPIO35, 64 samples each, every second");
  Serial.println("a driven pin is steady (spread < ~60 mV); a floating one drifts or sits near 0");
}

void loop() {
  for (int p : PINS) {
    Stats s = sample(p);
    int spread = s.hi - s.lo;
    const char *verdict =
        spread > 150      ? "FLOATING (noisy)" :
        s.mean < 60       ? "~0 V: floating or pulled to GND" :
                            "DRIVEN: steady voltage, something is on it";
    Serial.printf("GPIO%d  mean %4d mV  min %4d  max %4d  spread %3d  -> %s",
                  p, s.mean, s.lo, s.hi, spread, verdict);
    if (s.mean >= 60 && spread <= 150)
      Serial.printf("  (x2 = %d mV if it's a 100k/100k divider)", s.mean * 2);
    Serial.println();
  }
  Serial.println();
  delay(1000);
}
