#import <Foundation/Foundation.h>

@interface AudioStatsEWMA : NSObject

@property (nonatomic, readonly) double output;
@property (nonatomic, assign) double alpha;

- (instancetype)init;
- (instancetype)initWithAlpha:(double)alpha;
- (double)addSample:(double)input;

@end
