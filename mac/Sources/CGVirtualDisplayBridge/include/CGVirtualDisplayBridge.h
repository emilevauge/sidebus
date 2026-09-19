//
//  Declarations of the private CoreGraphics classes that create a virtual display.
//
//  These interfaces are taken from the DeskPad project, under the MIT licence:
//  https://github.com/Stengo/DeskPad
//  Copyright (c) 2022 Stengo
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this
//  software and associated documentation files (the "Software"), to deal in the Software
//  without restriction, including without limitation the rights to use, copy, modify,
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//  permit persons to whom the Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be included in all copies
//  or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
//  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
//  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
//  These classes belong to no public API: they can vanish with any macOS release.
//  Everything goes through `VirtualDisplayProvider`, and failure falls back to an existing
//  display.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@property(readonly, nonatomic) uint32_t width;
@property(readonly, nonatomic) uint32_t height;
@property(readonly, nonatomic) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
/// 1 active les modes HiDPI, sans quoi l'affichage est soit flou, soit minuscule.
@property(nonatomic, assign) uint32_t hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSString *name;
@property(nonatomic, assign) uint32_t maxPixelsWide;
@property(nonatomic, assign) uint32_t maxPixelsHigh;
/// Declared physical size. This is what sets the density, and so the sharpness.
@property(nonatomic, assign) CGSize sizeInMillimeters;
@property(nonatomic, assign) uint32_t serialNum;
@property(nonatomic, assign) uint32_t productID;
@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, copy) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) uint32_t vendorID;
@property(readonly, nonatomic) uint32_t productID;
@property(readonly, nonatomic) uint32_t serialNum;
@property(readonly, nonatomic) NSString *name;
@property(readonly, nonatomic) CGSize sizeInMillimeters;
@property(readonly, nonatomic) uint32_t maxPixelsWide;
@property(readonly, nonatomic) uint32_t maxPixelsHigh;
@end

NS_ASSUME_NONNULL_END
