// JoyCon2Bridge: Joy-Con 2 (Switch 2) input for BCD on iPhone, loaded into the app by scripts/patch.sh.
//
// iOS doesn't pair Joy-Con 2 as game controllers, so this talks to them over Bluetooth LE itself and
// shows BCD one ordinary controller: a GameController "snapshot" controller (public API) that it adds to
// +[GCController controllers] and fills from the Joy-Cons' input reports. BCD reads it like any pad.
//
// Protocol from ndeadly/switch2_controller_research (bluetooth_interface.md, hid_reports.md) and
// Nadeflore/switch2-controllers (controller.py). Nothing is written to the Joy-Con's pairing memory: it
// stays paired to the console. To connect, hold the Joy-Con's sync button until its lights run.
//
// Buttons and sticks confirmed working on an iPhone Duo with BCD 0.1.653 (2026-11-13).
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>

#define JCLog(fmt, ...) NSLog(@"[joycon2] " fmt, ##__VA_ARGS__)

static NSString *const kInputUUID = @"ab7de9be-89fe-49ad-828f-118f09df7fd2";     // input report 0x05, notify
static NSString *const kCommandUUID = @"649d4ac9-8eb7-4e6c-af44-1ea54fe5f005";   // basic command, write
static NSString *const kResponseUUID = @"c765a961-d9d8-4d36-a20a-5315b111836a";  // command response, notify

enum { kPidRight = 0x2066, kPidLeft = 0x2067 };
enum {   // input report button bits (little-endian u32 at offset 4)
  kY = 1u << 0, kX = 1u << 1, kB = 1u << 2, kA = 1u << 3, kR = 1u << 6, kZR = 1u << 7,
  kMinus = 1u << 8, kPlus = 1u << 9, kRStick = 1u << 10, kLStick = 1u << 11, kHome = 1u << 12,
  kDown = 1u << 16, kUp = 1u << 17, kRight = 1u << 18, kLeft = 1u << 19, kL = 1u << 22, kZL = 1u << 23,
};
// Stick calibration in the Joy-Con's memory: 9 bytes, three 12-bit pairs (centre, travel above it, travel
// below it). The user's calibration is all ff when the stick was never recalibrated on a console.
enum { kUserCalibration = 0x1fc042, kFactoryCalibration = 0x0130a8, kCalibrationLength = 0x0b };
static const float kFallbackRange = 1100;   // counts from centre to edge until the calibration is read
static const float kOuterMargin = 0.93f;    // full deflection a little before the mechanical edge
static const float kDeadzone = 0.08f;

static GCController *gVirtual;   // main thread only; non-nil while a Joy-Con is connected
static NSArray<GCController *> *(*gOrigControllers)(id, SEL);

static NSArray<GCController *> *JCControllers(id self, SEL _cmd) {
  NSArray<GCController *> *real = gOrigControllers(self, _cmd) ?: @[];
  GCController *virtual = gVirtual;
  return virtual ? [real arrayByAddingObject:virtual] : real;
}

@interface JCSide : NSObject
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBCharacteristic *command;
@property(nonatomic) BOOL live, centred, calibrated;
@property(nonatomic) uint32_t buttons;
@property(nonatomic) int cx, cy;
@property(nonatomic) float maxX, maxY, minX, minY;   // travel each way from the centre, in raw counts
@property(nonatomic) float x, y;
@end
@implementation JCSide
@end

@interface JCBridge : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@end

@implementation JCBridge {
  CBCentralManager *_central;
  JCSide *_left, *_right;
}

- (instancetype)init {
  if ((self = [super init])) {
    _left = [JCSide new];
    _right = [JCSide new];
    _central = [[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
  }
  return self;
}

- (JCSide *)sideFor:(CBPeripheral *)peripheral {
  if (_left.peripheral == peripheral) return _left;
  if (_right.peripheral == peripheral) return _right;
  return nil;
}

- (void)scan {
  if (_central.state != CBManagerStatePoweredOn) return;
  if (_left.peripheral && _right.peripheral) { [_central stopScan]; return; }
  if (!_central.isScanning) [_central scanForPeripheralsWithServices:nil options:nil];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  JCLog(@"bluetooth state %ld", (long)central.state);
  [self scan];
}

// Manufacturer data: 53 05 (Nintendo) 01 00 03, vendor ID (7e 05), product ID, ...
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisement RSSI:(NSNumber *)RSSI {
  NSData *data = advertisement[CBAdvertisementDataManufacturerDataKey];
  if (data.length < 9) return;
  const uint8_t *b = data.bytes;
  if (b[0] != 0x53 || b[1] != 0x05 || b[5] != 0x7e || b[6] != 0x05) return;
  int pid = b[7] | b[8] << 8;
  JCSide *side = pid == kPidLeft ? _left : pid == kPidRight ? _right : nil;
  if (!side || side.peripheral) return;
  JCLog(@"found %@ Joy-Con 2, connecting", side == _left ? @"left" : @"right");
  side.peripheral = peripheral;
  peripheral.delegate = self;
  [central connectPeripheral:peripheral options:nil];
  [self scan];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
  [peripheral discoverServices:nil];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
  for (CBService *service in peripheral.services) [peripheral discoverCharacteristics:nil forService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
  JCSide *side = [self sideFor:peripheral];
  if (!side) return;
  for (CBCharacteristic *c in service.characteristics) {
    if ([c.UUID isEqual:[CBUUID UUIDWithString:kInputUUID]] || [c.UUID isEqual:[CBUUID UUIDWithString:kResponseUUID]]) {
      [peripheral setNotifyValue:YES forCharacteristic:c];
    } else if ([c.UUID isEqual:[CBUUID UUIDWithString:kCommandUUID]]) {
      side.command = c;
      // Set player LED 1, so the Joy-Con shows it is connected: command 0x09, subcommand 0x07.
      static const uint8_t led[] = {0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0};
      CBCharacteristicWriteType type = (c.properties & CBCharacteristicPropertyWriteWithoutResponse)
          ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
      [peripheral writeValue:[NSData dataWithBytes:led length:sizeof led] forCharacteristic:c type:type];
      // Once the response notification is on, ask for the stick calibration.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        [self read:kUserCalibration from:side];
      });
    }
  }
}

// Memory read: command 0x02, subcommand 0x04, then length, 7e 00 00, address.
- (void)read:(uint32_t)address from:(JCSide *)side {
  CBCharacteristic *c = side.command;
  if (!c || side.peripheral.state != CBPeripheralStateConnected) return;
  const uint8_t read[] = {0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00, kCalibrationLength, 0x7e, 0x00, 0x00,
                          address & 0xff, address >> 8 & 0xff, address >> 16 & 0xff, address >> 24};
  CBCharacteristicWriteType type = (c.properties & CBCharacteristicPropertyWriteWithoutResponse)
      ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
  [side.peripheral writeValue:[NSData dataWithBytes:read length:sizeof read] forCharacteristic:c type:type];
}

// The answer: an 8-byte header (command, 01 = ok), then length, 3 bytes, the address, the data.
- (void)response:(NSData *)data from:(JCSide *)side {
  const uint8_t *b = data.bytes;
  if (data.length < 16 + 9 || b[0] != 0x02 || b[1] != 0x01) return;
  uint32_t address = b[12] | b[13] << 8 | b[14] << 16 | (uint32_t)b[15] << 24;
  const uint8_t *d = b + 16;
  if (address == kUserCalibration && d[0] == 0xff && d[1] == 0xff && d[2] == 0xff) {
    [self read:kFactoryCalibration from:side];
    return;
  }
  if (address != kUserCalibration && address != kFactoryCalibration) return;
  int v[6];
  for (int i = 0; i < 3; i++) {
    v[2 * i] = d[3 * i] | (d[3 * i + 1] & 0x0f) << 8;
    v[2 * i + 1] = d[3 * i + 1] >> 4 | d[3 * i + 2] << 4;
  }
  // Sanity: a centre near the middle of 0...4095 and a travel that could be a stick's.
  for (int i = 2; i < 6; i++) if (v[i] < 300 || v[i] > 2400) return;
  if (abs(v[0] - 2048) > 700 || abs(v[1] - 2048) > 700) return;
  side.cx = v[0]; side.cy = v[1]; side.centred = YES;
  side.maxX = v[2]; side.maxY = v[3]; side.minX = v[4]; side.minY = v[5];
  side.calibrated = YES;
  JCLog(@"%@ stick calibration (%s): centre %d,%d up %d,%d down %d,%d", side == _left ? @"left" : @"right",
        address == kUserCalibration ? "user" : "factory", v[0], v[1], v[2], v[3], v[4], v[5]);
}

// Input report 0x05 without its report ID: buttons u32 at 4, left stick at 10, right stick at 13
// (each stick is 3 bytes: 12-bit x, then 12-bit y).
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
  JCSide *side = [self sideFor:peripheral];
  NSData *data = characteristic.value;
  if (!side) return;
  if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:kResponseUUID]]) { [self response:data from:side]; return; }
  if (data.length < 16 || ![characteristic.UUID isEqual:[CBUUID UUIDWithString:kInputUUID]]) return;
  const uint8_t *b = data.bytes;
  const uint8_t *s = b + (side == _left ? 10 : 13);
  int rx = s[0] | (s[1] & 0x0f) << 8, ry = s[1] >> 4 | s[2] << 4;
  if (!side.centred) {   // until the calibration arrives: the stick is at rest when the Joy-Con connects
    side.cx = rx; side.cy = ry; side.centred = YES;
  }
  side.buttons = b[4] | b[5] << 8 | b[6] << 16 | (uint32_t)b[7] << 24;
  BOOL cal = side.calibrated;
  side.x = [self axis:rx - side.cx up:cal ? side.maxX : kFallbackRange down:cal ? side.minX : kFallbackRange];
  side.y = [self axis:ry - side.cy up:cal ? side.maxY : kFallbackRange down:cal ? side.minY : kFallbackRange];
  if (!side.live) {
    side.live = YES;
    JCLog(@"%@ Joy-Con 2 is sending input", side == _left ? @"left" : @"right");
  }
  [self publish];
}

// -1...1 from a raw offset: full at kOuterMargin of the travel, zero inside the dead zone, linear between.
- (float)axis:(int)raw up:(float)up down:(float)down {
  float v = raw / ((raw >= 0 ? up : down) * kOuterMargin);
  float size = fabsf(v);
  if (size < kDeadzone) return 0;
  size = fminf(1, (size - kDeadzone) / (1 - kDeadzone));
  return v < 0 ? -size : size;
}

- (void)publish {
  BOOL any = _left.live || _right.live;
  if (any && !gVirtual) {
    gVirtual = [GCController controllerWithExtendedGamepad];
    JCLog(@"virtual controller on");
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:gVirtual];
  } else if (!any && gVirtual) {
    GCController *gone = gVirtual;
    gVirtual = nil;
    JCLog(@"virtual controller off");
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:gone];
    return;
  }
  GCExtendedGamepad *pad = gVirtual.extendedGamepad;
  if (!pad) return;
  uint32_t l = _left.live ? _left.buttons : 0, r = _right.live ? _right.buttons : 0;
#define SET(input, on) [input setValue:(on) ? 1 : 0]
  // By position, as Windows games expect: Nintendo B is the bottom button, Xbox A.
  SET(pad.buttonA, r & kB); SET(pad.buttonB, r & kA); SET(pad.buttonX, r & kY); SET(pad.buttonY, r & kX);
  SET(pad.leftShoulder, l & kL); SET(pad.rightShoulder, r & kR);
  SET(pad.leftTrigger, l & kZL); SET(pad.rightTrigger, r & kZR);
  SET(pad.leftThumbstickButton, l & kLStick); SET(pad.rightThumbstickButton, r & kRStick);
  SET(pad.buttonMenu, r & kPlus); SET(pad.buttonOptions, l & kMinus); SET(pad.buttonHome, r & kHome);
#undef SET
  [pad.dpad setValueForXAxis:(l & kRight ? 1 : 0) - (l & kLeft ? 1 : 0) yAxis:(l & kUp ? 1 : 0) - (l & kDown ? 1 : 0)];
  [pad.leftThumbstick setValueForXAxis:_left.live ? _left.x : 0 yAxis:_left.live ? _left.y : 0];
  [pad.rightThumbstick setValueForXAxis:_right.live ? _right.x : 0 yAxis:_right.live ? _right.y : 0];
  // BCD samples a pad when its valueChangedHandler runs; a snapshot's setters may not run it.
  GCExtendedGamepadValueChangedHandler handler = pad.valueChangedHandler;
  if (handler) handler(pad, pad.buttonA);
}

- (void)drop:(CBPeripheral *)peripheral why:(NSError *)error {
  JCSide *side = [self sideFor:peripheral];
  if (!side) return;
  JCLog(@"%@ Joy-Con 2 gone: %@", side == _left ? @"left" : @"right", error.localizedDescription ?: @"disconnected");
  side.peripheral = nil; side.command = nil; side.live = NO; side.centred = NO; side.calibrated = NO; side.buttons = 0;
  [self publish];
  [self scan];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
  [self drop:peripheral why:error];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
  [self drop:peripheral why:error];
}

@end

static JCBridge *gBridge;

__attribute__((constructor)) static void JCLoad(void) {
  Method method = class_getClassMethod(GCController.class, @selector(controllers));
  if (!method) return;
  gOrigControllers = (void *)method_setImplementation(method, (IMP)JCControllers);
  // After launch, so the Bluetooth permission prompt doesn't land on the app's first frame.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    gBridge = [JCBridge new];
  });
}
