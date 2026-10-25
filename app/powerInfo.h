//
//  powerInfo.h
//  app
//
//  Created by tsunami on 2025/4/19.
//
// power_info.h
#import <Foundation/Foundation.h>

// Declare functions to be exposed to Swift
float getRawSystemPower(void);
float getAdapterPower(void);
float getAdapterVoltage(void);
float getAdapterAmperage(void);
float getBatteryVoltage(void);
float getBatteryAmperage(void);
float getBatteryPower(void);
NSString *_Nonnull getChargingStatus(void);
float getBatteryTemperature(void);

// Battery charge in percent as shown by macOS, read live from the SMC. -1 on failure.
int getBatteryUIPercent(void);

// macOS Charge Limit (System Settings > Battery), read without privileges. -1 on failure.
int getChargeLimit(void);
int isChargeLimitEnabled(void);

// Change macOS Charge Limit without privileges. Only 80-100% is accepted.
BOOL setChargeLimit(int limit);
BOOL setChargeLimitEnabled(BOOL enabled);
