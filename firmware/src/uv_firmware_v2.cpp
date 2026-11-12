#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <PubSubClient.h>
#include <HTTPClient.h>
#include <NetworkClientSecure.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Preferences.h>

// ================= 1. DEFAULT WIFI & CLOUD CREDENTIALS =================
const char* DEFAULT_WIFI_SSID   = "IB707";
const char* DEFAULT_WIFI_PASS   = "IB707IB707";

const char* MQTT_BROKER         = "broker.hivemq.com";
const int   MQTT_PORT           = 1883;
const char* MQTT_TOPIC          = "venkat_iot/sensors/uv/node_01";

const char* DEFAULT_INFLUX_URL  = "https://us-east-1-1.aws.cloud2.influxdata.com/api/v2/write?org=IOT&bucket=uv_sensor_data&precision=s";
const char* DEFAULT_INFLUX_TOK  = "Dbzt7IHP3G4E4McgOmsRBrZLUaK2fsEgexNVFzYSQI1V2PhqWbL6SFhB64Vg-jOY6HQIu7BibH8jkSQvHqLNWw==";

// ================= 2. PIN & HARDWARE DEFINITIONS =================
#define UV_SENSOR_PIN 2   // GUVA-S12SD SIG pin (ADC1_CH2)
#define I2C_SDA_PIN   8   // OLED SDA pin
#define I2C_SCL_PIN   9   // OLED SCL pin
#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
WebServer server(80);
WiFiClient espClient;
PubSubClient mqttClient(espClient);
Preferences prefs;

String activeSsid;
String activePass;
String activeInfluxUrl;
String activeInfluxToken;

// ================= 3. DSP FILTER & CALIBRATION STATE =================
const float UVI_THRESHOLDS[12] = {
  50.0f, 227.0f, 318.0f, 408.0f, 503.0f, 606.0f,
  696.0f, 795.0f, 881.0f, 976.0f, 1079.0f, 1170.0f
};

float medianBuf[9] = {0};
int   medianIdx    = 0;
int   medianCount  = 0;

bool  kalmanInitialized = false;
float kalX = 0.0f, kalP = 1.0f;
float hybX = 0.0f, hybP = 1.0f;

float currentMvRaw      = 0.0f;
float currentMvMedian   = 0.0f;
float currentMvKalman   = 0.0f;
float currentMvHybrid   = 0.0f;
float currentUviCal     = 0.0f;
float currentUviLinOld  = 0.0f;
int   currentUviInt     = 0;
String currentRisk      = "Low";

unsigned long lastSampleMs = 0;
unsigned long lastCloudMs  = 0;

// ================= 4. CALIBRATION FUNCTIONS =================
int lookupDiscreteUVI(float mv) {
  float clamped = constrain(mv, 0.0f, 1250.0f);
  if (clamped < 50.0f) return 0;
  for (int uvi = 11; uvi >= 1; uvi--) {
    if (clamped >= UVI_THRESHOLDS[uvi]) return uvi;
  }
  return 0;
}

float calculateCalibratedUVI(float mv) {
  float clamped = constrain(mv, 0.0f, 1250.0f);
  if (clamped < 50.0f) return 0.0f;
  if (clamped >= 1170.0f) return 11.0f + (clamped - 1170.0f) / 91.0f;
  for (int i = 0; i < 11; i++) {
    float vLow  = UVI_THRESHOLDS[i];
    float vHigh = UVI_THRESHOLDS[i + 1];
    if (clamped >= vLow && clamped <= vHigh) {
      return (float)i + (clamped - vLow) / (vHigh - vLow);
    }
  }
  return 0.0f;
}

String getRiskCategory(float uvi) {
  if (uvi < 3.0f)  return "Low";
  if (uvi < 6.0f)  return "Moderate";
  if (uvi < 8.0f)  return "High";
  if (uvi < 11.0f) return "Very high";
  return "Extreme";
}

// ================= 5. 3-TIER DSP FILTER PIPELINE =================
float readAveragedMilliVolts() {
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) {
    sum += analogReadMilliVolts(UV_SENSOR_PIN);
    delayMicroseconds(200);
  }
  return (float)sum / 16.0f;
}

float computeMedian9(float sample) {
  medianBuf[medianIdx] = sample;
  medianIdx = (medianIdx + 1) % 9;
  if (medianCount < 9) medianCount++;

  float sorted[9];
  for (int i = 0; i < medianCount; i++) {
    sorted[i] = medianBuf[i];
  }
  for (int i = 0; i < medianCount - 1; i++) {
    for (int j = i + 1; j < medianCount; j++) {
      if (sorted[j] < sorted[i]) {
        float tmp = sorted[i];
        sorted[i] = sorted[j];
        sorted[j] = tmp;
      }
    }
  }
  return sorted[medianCount / 2];
}

float computeKalman1D(float measurement, float &x, float &p, float q, float r) {
  p += q;
  float kG = p / (p + r);
  x += kG * (measurement - x);
  p = (1.0f - kG) * p;
  return x;
}

void updateFiltersAndSensors() {
  float raw = readAveragedMilliVolts();

  // 1. Eliminate ESP32-C3 ADC zero-offset hardware floor (< 30 mV)
  if (raw < 30.0f) {
    raw = 0.0f;
  }

  // 2. Clamp Raw mV to [0.0, 1250.0] identical to the 3 filters
  currentMvRaw = constrain(raw, 0.0f, 1250.0f);

  // 3. Compute Median Filter (Window = 9)
  currentMvMedian = constrain(computeMedian9(currentMvRaw), 0.0f, 1250.0f);

  // 4. Initialize Kalman states on first sample
  if (!kalmanInitialized) {
    kalX = currentMvRaw;
    hybX = currentMvMedian;
    kalmanInitialized = true;
  }

  // 5. Compute Standalone 1D Kalman and Hybrid (Median -> Kalman)
  currentMvKalman = constrain(computeKalman1D(currentMvRaw, kalX, kalP, 0.05f, 2.5f), 0.0f, 1250.0f);
  currentMvHybrid = constrain(computeKalman1D(currentMvMedian, hybX, hybP, 0.05f, 1.5f), 0.0f, 1250.0f);

  // 6. Compute Calibrated UVI & Risk Category from Hybrid Filter
  currentUviCal    = calculateCalibratedUVI(currentMvHybrid);
  currentUviLinOld = currentMvHybrid / 100.0f;
  currentUviInt    = lookupDiscreteUVI(currentMvHybrid);
  currentRisk      = getRiskCategory(currentUviCal);
}

// ================= 6. HTTP SERVER ENDPOINTS (/data, /scan, /wifi) =================
String buildTelemetryJson() {
  JsonDocument doc;
  doc["mv_raw"]             = serialized(String(currentMvRaw, 2));
  doc["mv_median"]          = serialized(String(currentMvMedian, 2));
  doc["mv_kalman"]          = serialized(String(currentMvKalman, 2));
  doc["mv_hybrid"]          = serialized(String(currentMvHybrid, 2));
  doc["uv_index_estimated"] = serialized(String(currentUviCal, 3));
  doc["uvi_lookup_int"]     = currentUviInt;
  doc["uvi_linear_old"]     = serialized(String(currentUviLinOld, 3));
  doc["risk"]               = currentRisk;
  doc["rssi_dbm"]           = WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0;

  String output;
  serializeJson(doc, output);
  return output;
}

void handleGetData() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", buildTelemetryJson());
}

void handleScanWifi() {
  int n = WiFi.scanNetworks();
  JsonDocument doc;
  JsonArray arr = doc["networks"].to<JsonArray>();
  for (int i = 0; i < n; i++) {
    JsonObject net = arr.add<JsonObject>();
    net["ssid"] = WiFi.SSID(i);
    net["rssi"] = WiFi.RSSI(i);
  }
  String out;
  serializeJson(doc, out);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", out);
}

void handlePostWifi() {
  String newSsid = server.arg("ssid");
  String newPass = server.arg("pass");
  String newUrl  = server.arg("influx_url");
  String newTok  = server.arg("influx_token");

  if (newSsid.length() > 0) {
    prefs.begin("uv_cfg_v2", false);
    prefs.putString("ssid", newSsid);
    prefs.putString("pass", newPass);
    if (newUrl.length() > 0) prefs.putString("inf_url", newUrl);
    if (newTok.length() > 0) prefs.putString("inf_tok", newTok);
    prefs.end();

    activeSsid = newSsid;
    activePass = newPass;
    if (newUrl.length() > 0) activeInfluxUrl = newUrl;
    if (newTok.length() > 0) activeInfluxToken = newTok;

    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.send(200, "application/json", "{\"status\":\"saved_reconnecting\"}");
    delay(500);
    WiFi.disconnect();
    WiFi.begin(activeSsid.c_str(), activePass.c_str());
  } else {
    server.send(400, "application/json", "{\"error\":\"missing_ssid\"}");
  }
}

// ================= 7. CLOUD SYNC (HIVEMQ & INFLUXDB) =================
void publishToHiveMq() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!mqttClient.connected()) {
    String clientId = "esp32c3_uv_v2_" + String(random(1000, 9999));
    mqttClient.connect(clientId.c_str());
  }
  if (mqttClient.connected()) {
    String payload = buildTelemetryJson();
    mqttClient.publish(MQTT_TOPIC, payload.c_str());
  }
}

void writeToInfluxDb() {
  if (WiFi.status() != WL_CONNECTED || activeInfluxUrl.length() == 0) return;

  NetworkClientSecure client;
  client.setInsecure();
  HTTPClient https;

  if (https.begin(client, activeInfluxUrl)) {
    https.addHeader("Authorization", "Token " + activeInfluxToken);
    https.addHeader("Content-Type", "text/plain; charset=utf-8");

    String lineProtocol = "uv_measurement,sensor=GUVA-S12SD,node=esp32c3 "
                          "voltage_raw_mv=" + String(currentMvRaw, 2) + ","
                          "voltage_median_mv=" + String(currentMvMedian, 2) + ","
                          "voltage_kalman_mv=" + String(currentMvKalman, 2) + ","
                          "voltage_hybrid_mv=" + String(currentMvHybrid, 2) + ","
                          "uv_index_estimated=" + String(currentUviCal, 3) + ","
                          "uv_index_lookup=" + String(currentUviInt) + "i,"
                          "rssi_dbm=" + String(WiFi.RSSI()) + "i";

    https.POST(lineProtocol);
    https.end();
  }
}

// ================= 8. OLED DISPLAY RENDERER =================
void updateOledDisplay() {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);

  display.setCursor(0, 0);
  if (WiFi.status() == WL_CONNECTED) {
    display.print("IP:");
    display.println(WiFi.localIP());
  } else {
    display.println("AP: 192.168.4.1");
  }

  display.setCursor(0, 12);
  display.printf("Raw:%4.0fmV Hyb:%4.0fmV\n", currentMvRaw, currentMvHybrid);

  display.setCursor(0, 24);
  display.printf("Med:%4.0fmV Kal:%4.0fmV\n", currentMvMedian, currentMvKalman);

  display.setCursor(0, 38);
  display.setTextSize(2);
  display.printf("UVI: %.2f\n", currentUviCal);

  display.setTextSize(1);
  display.setCursor(0, 56);
  display.printf("Risk: %s", currentRisk.c_str());
  display.display();
}

// ================= 9. SETUP & MAIN LOOP =================
void setup() {
  Serial.begin(115200);
  analogReadResolution(12);
  analogSetPinAttenuation(UV_SENSOR_PIN, ADC_11db);

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  display.clearDisplay();
  display.display();

  prefs.begin("uv_cfg_v2", true);
  activeSsid        = prefs.getString("ssid", DEFAULT_WIFI_SSID);
  activePass        = prefs.getString("pass", DEFAULT_WIFI_PASS);
  activeInfluxUrl   = prefs.getString("inf_url", DEFAULT_INFLUX_URL);
  activeInfluxToken = prefs.getString("inf_tok", DEFAULT_INFLUX_TOK);
  prefs.end();

  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP("ESP32_UV_WiFi_Setup");
  WiFi.begin(activeSsid.c_str(), activePass.c_str());

  unsigned long startAttempt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startAttempt < 10000) {
    delay(250);
  }

  server.on("/data", HTTP_GET, handleGetData);
  server.on("/scan", HTTP_GET, handleScanWifi);
  server.on("/wifi", HTTP_POST, handlePostWifi);
  server.begin();

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
}

void loop() {
  server.handleClient();
  if (WiFi.status() == WL_CONNECTED) {
    mqttClient.loop();
  }

  unsigned long now = millis();
  if (now - lastSampleMs >= 1000) {
    lastSampleMs = now;
    updateFiltersAndSensors();
    updateOledDisplay();
  }

  if (now - lastCloudMs >= 5000) {
    lastCloudMs = now;
    publishToHiveMq();
    writeToInfluxDb();
  }
}