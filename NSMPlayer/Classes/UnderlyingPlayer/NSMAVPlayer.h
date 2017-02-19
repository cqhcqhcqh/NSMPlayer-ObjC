//
//  NSMAVPlayer.h
//  AVFoundataion_Playback
//
//  Created by chengqihan on 2017/2/9.
//  Copyright © 2017年 chengqihan. All rights reserved.
//
/* Note that NSNotifications posted by AVPlayerItem may be posted on a different thread from the one on which the observer was registered. */


#import "NSMUnderlyingPlayer.h"

@interface NSMAVPlayer : NSMUnderlyingPlayer

@property (nonatomic, strong) AVPlayer *avplayer;


@end