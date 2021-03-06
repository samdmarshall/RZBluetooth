//
//  RZBSimulatedDevice.m
//  RZBluetooth
//
//  Created by Brian King on 8/4/15.
//  Copyright (c) 2015 Raizlabs. All rights reserved.
//

#import "RZBSimulatedDevice.h"
#import "RZBSimulatedCentral.h"
#import "RZBLog+Private.h"

@interface RZBSimulatedDevice ()

@property (strong, nonatomic, readonly) NSMutableDictionary *readHandlers;
@property (strong, nonatomic, readonly) NSMutableDictionary *writeHandlers;
@property (strong, nonatomic, readonly) NSMutableDictionary *subscribeHandlers;
@property (strong, nonatomic, readonly) NSOperationQueue *operationQueue;

@end

@implementation RZBSimulatedDevice

- (instancetype)init
{
    self = [self initWithQueue:nil options:@{}];
    return self;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                      options:(NSDictionary *)options;
{
    self = [super init];
    if (self) {
        _queue = queue ?: dispatch_get_main_queue();
        _readHandlers = [NSMutableDictionary dictionary];
        _writeHandlers = [NSMutableDictionary dictionary];
        _subscribeHandlers = [NSMutableDictionary dictionary];
        _peripheralManager = [[CBPeripheralManager alloc] initWithDelegate:self
                                                                     queue:queue
                                                                   options:options];
        _values = [NSMutableDictionary dictionary];
        _operationQueue = [[NSOperationQueue alloc] init];
        _operationQueue.suspended = true;
    }
    return self;
}

- (CBMutableService *)serviceForRepresentable:(id<RZBBluetoothRepresentable>)representable isPrimary:(BOOL)isPrimary
{
    CBMutableService *service = [[CBMutableService alloc] initWithType:[representable.class serviceUUID] primary:isPrimary];

    NSDictionary *characteristicsByUUID = [representable.class characteristicUUIDsByKey];
    NSMutableArray *characteristics = [NSMutableArray array];
    [characteristicsByUUID enumerateKeysAndObjectsUsingBlock:^(NSString *key, CBUUID *UUID, BOOL *stop) {
        CBCharacteristicProperties properties = [representable.class characteristicPropertiesForKey:key];
        CBAttributePermissions permissions = CBAttributePermissionsReadable;
        id value = [representable valueForKey:key];

        if (value) {
            NSData *data = [representable.class dataForKey:key fromValue:value];
            CBMutableCharacteristic *characteristic = [[CBMutableCharacteristic alloc] initWithType:UUID
                                                                                         properties:properties
                                                                                              value:data
                                                                                        permissions:permissions];
            [characteristics addObject:characteristic];
        }
    }];
    service.characteristics = characteristics;
    return service;
}

- (void)startAdvertising
{
    NSAssert(self.peripheralManager.isAdvertising == NO, @"Already Advertising");
    NSAssert([self advertisedServices].count > 0, @"The device has no primary services");
    [self.operationQueue addOperationWithBlock:^{
        [self.peripheralManager startAdvertising:@{CBAdvertisementDataServiceUUIDsKey:[self advertisedServices]}];
    }];
}

- (void)stopAdvertising
{
    [self.operationQueue addOperationWithBlock:^{
        [self.peripheralManager stopAdvertising];
    }];
}

- (NSArray *)advertisedServices
{
    @synchronized (self.services) {
        return [self.services filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isPrimary == YES"]];
    }
}

- (void)addService:(CBMutableService *)service
{
    @synchronized (self.services) {
        [[self mutableArrayValueForKey:@"services"] addObject:service];
    }
    [self.operationQueue addOperationWithBlock:^{
        [self.peripheralManager addService:service];
    }];
}

- (void)addBluetoothRepresentable:(id<RZBBluetoothRepresentable>)bluetoothRepresentable isPrimary:(BOOL)isPrimary
{
    NSParameterAssert(bluetoothRepresentable);
    CBMutableService *service = [self serviceForRepresentable:bluetoothRepresentable isPrimary:isPrimary];
    [self addService:service];
}

- (void)addReadCallbackForCharacteristicUUID:(CBUUID *)characteristicUUID handler:(RZBATTRequestHandler)handler;
{
    NSParameterAssert(characteristicUUID);
    NSParameterAssert(handler);
    @synchronized (self.readHandlers) {
        self.readHandlers[characteristicUUID] = [handler copy];
    }
}

- (void)addWriteCallbackForCharacteristicUUID:(CBUUID *)characteristicUUID handler:(RZBATTRequestHandler)handler;
{
    NSParameterAssert(characteristicUUID);
    NSParameterAssert(handler);
    @synchronized (self.writeHandlers) {
        self.writeHandlers[characteristicUUID] = [handler copy];
    }
}

- (void)addSubscribeCallbackForCharacteristicUUID:(CBUUID *)characteristicUUID handler:(RZBNotificationHandler)handler
{
    NSParameterAssert(characteristicUUID);
    NSParameterAssert(handler);
    @synchronized (self.subscribeHandlers) {
        self.subscribeHandlers[characteristicUUID] = [handler copy];
    }
}

- (CBMutableCharacteristic *)characteristicForUUID:(CBUUID *)characteristicUUID
{
    @synchronized (self.services) {
        for (CBMutableService *service in self.services) {
            for (CBMutableCharacteristic *characteristic in service.characteristics) {
                if ([characteristic.UUID isEqual:characteristicUUID]) {
                    return characteristic;
                }
            }
        }
        return nil;
    }
}


#pragma mark - CBPeripheralManagerDelegate

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral
{
    RZBLogSimulatedDevice(@"%@ - %@", NSStringFromSelector(_cmd), peripheral);
    RZBLogSimulatedDevice(@"State=%d", (unsigned int)peripheral.state);

    RZBPeripheralManagerStateBlock stateChange = self.onStateChange;
    if (stateChange) {
        stateChange(peripheral.state);
    }

    _operationQueue.suspended = (peripheral.state != CBPeripheralManagerStatePoweredOn);
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didAddService:(CBService *)service error:(NSError *)error
{
    RZBLogSimulatedDevice(@"%@ -  %@", NSStringFromSelector(_cmd), error);
    RZBLogSimulatedDevice(@"Service=%@", service.UUID);
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didSubscribeToCharacteristic:(CBCharacteristic *)characteristic
{
    RZBLogSimulatedDevice(@"%@ -  %@", NSStringFromSelector(_cmd), characteristic.UUID);

    RZBNotificationHandler handler = nil;
    @synchronized (self.subscribeHandlers) {
        handler = self.subscribeHandlers[characteristic.UUID];
    }
    if (handler) {
        handler(YES);
    }
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral central:(CBCentral *)central didUnsubscribeFromCharacteristic:(CBCharacteristic *)characteristic
{
    RZBLogSimulatedDevice(@"%@ -  %@", NSStringFromSelector(_cmd), characteristic.UUID);

    RZBNotificationHandler handler = nil;
    @synchronized (self.subscribeHandlers) {
        handler = self.subscribeHandlers[characteristic.UUID];
    }
    if (handler) {
        handler(NO);
    }
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveReadRequest:(CBATTRequest *)request
{
    RZBLogSimulatedDevice(@"%@ -  %@", NSStringFromSelector(_cmd), request.characteristic.UUID);

    RZBATTRequestHandler read = nil;
    @synchronized (self.readHandlers) {
        read = self.readHandlers[request.characteristic.UUID];
    }
    CBATTError result = CBATTErrorRequestNotSupported;
    if (read) {
        result = read(request);
    }
    else {
        RZBLogSimulatedDevice(@"Unhandled read request %@", request);
    }
    [peripheral respondToRequest:request withResult:result];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveWriteRequests:(NSArray *)requests
{
    RZBLogSimulatedDevice(@"%@ -  %@", NSStringFromSelector(_cmd), RZBLogArray([requests valueForKeyPath:@"characteristic.UUID"]));

    CBATTError result = CBATTErrorSuccess;
    for (CBATTRequest *request in requests) {
        RZBATTRequestHandler write = nil;
        @synchronized(self.writeHandlers) {
            write = self.writeHandlers[request.characteristic.UUID];
        }
        if (write) {
            result = MAX(result, write(request));
        }
        else {
            RZBLogSimulatedDevice(@"Unhandled read request %@", request);
            result = MAX(result, CBATTErrorRequestNotSupported);
        }
    }
    [peripheral respondToRequest:requests.firstObject withResult:result];
}

@end
