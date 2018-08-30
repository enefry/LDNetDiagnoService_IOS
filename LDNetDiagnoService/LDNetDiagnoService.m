//
//  LDNetDiagnoService.m
//  LDNetDiagnoServieDemo
//
//  Created by 庞辉 on 14-10-29.
//  Copyright (c) 2014年 庞辉. All rights reserved.
//
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "LDNetDiagnoService.h"
#import "LDNetPing.h"
#import "LDNetTraceRoute.h"
#import "LDNetGetAddress.h"
#import "LDNetTimer.h"
#import "LDNetConnect.h"
#import "TRTraceroute.h"

#define TRLocalizedString(key) NSLocalizedStringFromTable(key, @"LDNetDiagnoService", @"")
static NSString *const kPingOpenServerIP = @"www.apple.com";
static NSString *const kCheckOutIPURL = @"http://vl7.net/ip";
static NSString *const kCheckOutIPURL2 = @"http://ipinfo.io/ip";
static NSString *const kCheckOutIPURL3 = @"http://ifconfig.me/ip";

@interface LDNetDiagnoService () <LDNetPingDelegate, LDNetTraceRouteDelegate,
                                  LDNetConnectDelegate> {
    NSString *_appCode;  //客户端标记
    NSString *_appName;
    NSString *_appVersion;
    NSString *_UID;       //用户ID
    NSString *_deviceID;  //客户端机器ID，如果不传入会默认取API提供的机器ID
    NSString *_carrierName;
    NSString *_ISOCountryCode;
    NSString *_MobileCountryCode;
    NSString *_MobileNetCode;

    NETWORK_TYPE _curNetType;
    NSString *_localIp;
    NSString *_outIp;
    NSString *_gatewayIp;
    NSArray *_dnsServers;
    NSArray *_hostAddress;


    NSMutableString *_logInfo;  //记录网络诊断log日志
    BOOL _isRunning;
    BOOL _connectSuccess;  //记录连接是否成功
    LDNetPing *_netPinger;
    LDNetTraceRoute *_traceRouter;
    LDNetConnect *_netConnect;
    TRTraceroute *_trTraceroute;
}

@end

@implementation LDNetDiagnoService
#pragma mark - public method
/**
 * 初始化网络诊断服务
 */
- (id)initWithAppCode:(NSString *)theAppCode
              appName:(NSString *)theAppName
           appVersion:(NSString *)theAppVersion
               userID:(NSString *)theUID
             deviceID:(NSString *)theDeviceID
              dormain:(NSString *)theDormain
          carrierName:(NSString *)theCarrierName
       ISOCountryCode:(NSString *)theISOCountryCode
    MobileCountryCode:(NSString *)theMobileCountryCode
        MobileNetCode:(NSString *)theMobileNetCode
{
    self = [super init];
    if (self) {
        _appCode = theAppCode;
        _appName = theAppName;
        _appVersion = theAppVersion;
        _UID = theUID;
        _deviceID = theDeviceID;
        _dormain = theDormain;
        _carrierName = theCarrierName;
        _ISOCountryCode = theISOCountryCode;
        _MobileCountryCode = theMobileCountryCode;
        _MobileNetCode = theMobileNetCode;

        _logInfo = [[NSMutableString alloc] initWithCapacity:20];
        _isRunning = NO;
    }

    return self;
}


/**
 * 开始诊断网络
 */
- (void)startNetDiagnosis
{
    if (!_dormain || [_dormain isEqualToString:@""]) return;
    _isRunning = YES;
    [_logInfo setString:@""];
    __weak __typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        [weakSelf runNetDiagnosis];
    });
}

-(void)runNetDiagnosis{
    //启动 runloop
    [NSRunLoop currentRunLoop];
    [self recordStepInfo:@"\n%@\n",TRLocalizedString(@"RTNetDiagnosisStart")];//开始网络诊断.
    [self recordCurrentAppVersion];
    [self recordLocalNetEnvironment];
    //未联网不进行任何检测
    if (_curNetType == 0) {
        _isRunning = NO;
        [self recordStepInfo:@"\n%@",TRLocalizedString(@"RTNetDiagnosisNoNetwork")];//当前主机未联网，请检查网络！
        [self recordStepInfo:@"\n%@\n",TRLocalizedString(@"RTNetDiagnosisFinish")];//网络诊断结束
        if (self.delegate && [self.delegate respondsToSelector:@selector(netDiagnosisDidEnd:)]) {
            [self.delegate netDiagnosisDidEnd:_logInfo];
        }
        return;
    }

    if (_isRunning) {
        [self recordStepInfo:@"\n%@",TRLocalizedString(@"RTNetDiagnosisBeginOutIpInfo")];
        [self recordOutIPInfo];
        [self recordStepInfo:@"%@",TRLocalizedString(@"RTNetDiagnosisFinishOutIpInfo")];
    }

    // connect诊断，同步过程, 如果TCP无法连接，检查本地网络环境
    if (_isRunning) {
        _connectSuccess = NO;
        [self recordStepInfo:@"\n%@",TRLocalizedString(@"RTNetDiagnosisBeginTcpConnect")];
        if ([_hostAddress count] > 0) {
            LDNetConnect*netConnect = [[LDNetConnect alloc] init];
            _netConnect = netConnect;
            _netConnect.delegate = self;
            for (int i = 0; i < [_hostAddress count]; i++) {
                [_netConnect runWithHostAddress:[_hostAddress objectAtIndex:i] port:80];
            }
        } else {
            [self recordStepInfo:@"%@",TRLocalizedString(@"RTNetDiagnosisDNSresolveError")];
        }
        [self recordStepInfo:@"%@\n",TRLocalizedString(@"RTNetDiagnosisFinishTcpConnect")];
    }

    // ping 外网地址, ping 目标地址
    if (_isRunning) {
        [self pingDialogsis:!_connectSuccess];
    }

    if (_isRunning) {
        //开始诊断traceRoute
        LDNetTraceRoute *traceRouter = [[LDNetTraceRoute alloc] initWithMaxTTL:TRACEROUTE_MAX_TTL
                                                        timeout:TRACEROUTE_TIMEOUT
                                                    maxAttempts:TRACEROUTE_ATTEMPTS
                                                           port:TRACEROUTE_PORT];
        _traceRouter = traceRouter;
        _traceRouter.delegate = self;
        if (_traceRouter) {
            [self recordStepInfo:@"\n%@",TRLocalizedString(@"RTNetDiagnosisBeginUDPTraceroute")];
            [_traceRouter doTraceRoute:_dormain];
            [self recordStepInfo:@"%@",TRLocalizedString(@"RTNetDiagnosisFinishUDPTraceroute")];
        }
    }

    if(_isRunning){
        [self recordStepInfo:@"\n%@",TRLocalizedString(@"RTNetDiagnosisBeginICMPTraceroute")];
        __weak __typeof(self)weakSelf = self;
        TRTraceroute *traceRouter =[TRTraceroute startTracerouteWithHost:[_hostAddress firstObject]
                                                        queue:nil
                                                 stepCallback:^(TRTracerouteRecord *record) {
                                                     [weakSelf recordStepInfo:[record description]];
                                                 } finish:^(NSArray<TRTracerouteRecord *> *results, BOOL succeed) {
                                                     [weakSelf recordStepInfo:@"%@",TRLocalizedString(succeed?@"RTNetDiagnosisICMPTracerouteSuccess":@"RTNetDiagnosisICMPTracerouteFail")];
                                                 }];

        _trTraceroute = traceRouter;
        [self recordStepInfo:@"%@",TRLocalizedString(@"RTNetDiagnosisFinishICMPTraceroute")];
    }
    [self recordStepInfo:@"\n%@\n",TRLocalizedString(@"RTNetDiagnosisFinish")];
    [self onFinishAll];
}


/**
 * 停止诊断网络, 清空诊断状态
 */
- (void)stopNetDialogsis
{
    if (_isRunning) {
        if (_netConnect != nil) {
            _netConnect.delegate = nil;
            [_netConnect stopConnect];
            _netConnect = nil;
        }

        if (_netPinger != nil) {
            [_netPinger stopPing];
            _netPinger.delegate = nil;
            _netPinger = nil;
        }

        if (_traceRouter != nil) {
            [_traceRouter stopTrace];
            _traceRouter.delegate = nil;
            _traceRouter = nil;
        }
        if(_trTraceroute !=nil){
            [_trTraceroute stopTrace];
        }
        _isRunning = NO;
    }
}


/**
 * 打印整体loginInfo；
 */
- (void)printLogInfo
{
    NSLog(@"\n%@\n", _logInfo);
}


#pragma mark -
#pragma mark - private method

/*!
 *  @brief  获取App相关信息
 */
- (void)recordCurrentAppVersion
{
    //输出应用版本信息和用户ID
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisAppCode"), _appCode]];
    NSDictionary *dicBundle = [[NSBundle mainBundle] infoDictionary];

    if (!_appName || [_appName isEqualToString:@""]) {
        _appName = [dicBundle objectForKey:@"CFBundleDisplayName"];
    }
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisAppDisplayName"), _appName]];

    if (!_appVersion || [_appVersion isEqualToString:@""]) {
        _appVersion = [dicBundle objectForKey:@"CFBundleShortVersionString"];
    }
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisAppVersion"), _appVersion]];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisUID"), _UID]];

    //输出机器信息
    UIDevice *device = [UIDevice currentDevice];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@", TRLocalizedString(@"RTNetDiagnosisDeviceName"),[device systemName]]];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisSystemVersion"), [device systemVersion]]];
    if (!_deviceID || [_deviceID isEqualToString:@""]) {
        _deviceID = [self uniqueAppInstanceIdentifier];
    }
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@", TRLocalizedString(@"RTNetDiagnosisMachineID"),_deviceID]];


    //运营商信息
    if (!_carrierName || [_carrierName isEqualToString:@""]) {
        CTTelephonyNetworkInfo *netInfo = [[CTTelephonyNetworkInfo alloc] init];
        CTCarrier *carrier = [netInfo subscriberCellularProvider];
        if (carrier != NULL) {
            _carrierName = [carrier carrierName];
            _ISOCountryCode = [carrier isoCountryCode];
            _MobileCountryCode = [carrier mobileCountryCode];
            _MobileNetCode = [carrier mobileNetworkCode];
        } else {
            _carrierName = @"";
            _ISOCountryCode = @"";
            _MobileCountryCode = @"";
            _MobileNetCode = @"";
        }
    }

    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@", TRLocalizedString(@"RTNetDiagnosisCarrierName") ,_carrierName]];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@", TRLocalizedString(@"RTNetDiagnosisISOCountryCode"), _ISOCountryCode]];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@", TRLocalizedString(@"RTNetDiagnosisMobileCountryCode"), _MobileCountryCode]];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@", TRLocalizedString(@"RTNetDiagnosisMobileNetworkCode"), _MobileNetCode]];
}


/*!
 *  @brief  获取本地网络环境信息
 */
- (void)recordLocalNetEnvironment
{
    [self recordStepInfo:[NSString stringWithFormat:@"\n%@:%@\n",TRLocalizedString(@"RTNetDiagnosisDiagnosisDomainName"),_dormain]];
    //判断是否联网以及获取网络类型
    NSArray *typeArr = [NSArray arrayWithObjects:@"2G", @"3G", @"4G", @"5G", @"wifi", nil];
    _curNetType = [LDNetGetAddress getNetworkTypeFromStatusBar];
    if (_curNetType == 0) {
        [self recordStepInfo:[NSString stringWithFormat:@"%@:%@",TRLocalizedString(@"RTNetDiagnosisNetworkStatus"),TRLocalizedString(@"RTNetDiagnosisNetworkStatusUnconnected")]];
    } else {
        [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisNetworkStatus"),TRLocalizedString(@"RTNetDiagnosisNetworkStatusConnected")]];
        if (_curNetType > 0 && _curNetType < 6) {
            [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisNetworkType"),[typeArr objectAtIndex:_curNetType - 1]]];
        }
    }

    //本地ip信息
    _localIp = [LDNetGetAddress deviceIPAdress];
    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisLocalIP"), _localIp]];

    if (_curNetType == NETWORK_TYPE_WIFI) {
        _gatewayIp = [LDNetGetAddress getGatewayIPAddress];
        [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisGatewary"), _gatewayIp]];
    } else {
        _gatewayIp = @"";
    }


    _dnsServers = [NSArray arrayWithArray:[LDNetGetAddress outPutDNSServers]];
    [self recordStepInfo:[NSString stringWithFormat:@"%@:%@",TRLocalizedString(@"RTNetDiagnosisLocalDNS"),[_dnsServers componentsJoinedByString:@", "]]];

    [self recordStepInfo:[NSString stringWithFormat:@"%@: %@",TRLocalizedString(@"RTNetDiagnosisRemoteDomain"),_dormain]];

    // host地址IP列表
    long time_start = [LDNetTimer getMicroSeconds];
    _hostAddress = [NSArray arrayWithArray:[LDNetGetAddress getDNSsWithDormain:_dormain]];
    long time_duration = [LDNetTimer computeDurationSince:time_start] / 1000;
    if ([_hostAddress count] == 0) {
        [self recordStepInfo:[NSString stringWithFormat:@"%@:%@",TRLocalizedString(@"RTNetDiagnosisDNSresolveResult"),TRLocalizedString(@"RTNetDiagnosisFail")]];
    } else {
        [self recordStepInfo:[NSString stringWithFormat:@"%@: %@ (%ldms)",TRLocalizedString(@"RTNetDiagnosisDNSresolveResult"),[_hostAddress componentsJoinedByString:@", "],time_duration]];
    }
}

/**
 * 使用接口获取用户的出口IP和DNS信息
 */
- (void)recordOutIPInfo
{
    // 初始化请求, 这里是变长的, 方便扩展
    NSArray*servers = @[kCheckOutIPURL,kCheckOutIPURL2,kCheckOutIPURL3];
    NSString*outip = nil;
    for(NSString*server in servers){
        NSMutableURLRequest *request =
        [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:server]
                                     cachePolicy:NSURLRequestUseProtocolCachePolicy
                                 timeoutInterval:10];
        // 发送同步请求, data就是返回的数据
        __block NSData *responseData = nil;
        __block NSError *responseError = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); //创建信号量
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            responseError = error;
            dispatch_semaphore_signal(semaphore);   //发送信号
        }];
        [task resume];
        dispatch_semaphore_wait(semaphore,DISPATCH_TIME_FOREVER);  //等待
        if (responseError != nil) {
            NSLog(@"error = %@", responseError);
            continue;
        }
        NSString *response = [[NSString alloc] initWithData:responseData encoding:0x80000632];
        outip = [response stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self recordStepInfo:outip];
        break;
    }
    if(outip==nil){
        [self recordStepInfo:@"%@:%@",TRLocalizedString(@"RTNetDiagnosisGetOutIpResult"),TRLocalizedString(@"RTNetDiagnosisFail")];
    }else{
        _outIp = outip;
        [self recordStepInfo:@"%@%@ :%@",TRLocalizedString(@"RTNetDiagnosisGetOutIpResult"),TRLocalizedString(@"RTNetDiagnosisSuccess"),outip];
    }
}


/**
 * 构建ping列表并进行ping诊断
 */
- (void)pingDialogsis:(BOOL)pingLocal
{
    //诊断ping信息, 同步过程
    NSMutableArray *pingAdd = [[NSMutableArray alloc] init];
    NSMutableArray *pingInfo = [[NSMutableArray alloc] init];
    if (pingLocal) {
        [pingAdd addObject:@"127.0.0.1"];
        [pingInfo addObject:TRLocalizedString(@"RTNetDiagnosisLocalhost")];
        [pingAdd addObject:_localIp];
        [pingInfo addObject:TRLocalizedString(@"RTNetDiagnosisLocalIP")];
        if (_gatewayIp && ![_gatewayIp isEqualToString:@""]) {
            [pingAdd addObject:_gatewayIp];
            [pingInfo addObject:TRLocalizedString(@"RTNetDiagnosisGatewary")];
        }
        if ([_dnsServers count] > 0) {
            [pingAdd addObject:[_dnsServers objectAtIndex:0]];
            [pingInfo addObject:TRLocalizedString(@"RTNetDiagnosisDNSServer")];
        }
    }

    //不管服务器解析DNS是否可达，均需要ping指定ip地址
    if([_localIp rangeOfString:@":"].location == NSNotFound){
        [pingAdd addObject:kPingOpenServerIP];
        [pingInfo addObject:TRLocalizedString(@"RTNetDiagnosisAppleServer")];
        [pingAdd addObject:_dormain];
        [pingInfo addObject:TRLocalizedString(@"RTNetDiagnosisTargetServer")];
    }

    [self recordStepInfo:@"\n%@",TRLocalizedString(@"RTNetDiagnosisBeginPing")];
    _netPinger = [[LDNetPing alloc] init];
    _netPinger.delegate = self;
    for (int i = 0; i < [pingAdd count]; i++) {
        [self recordStepInfo:[NSString stringWithFormat:@"Ping: %@ : %@",
                                                        [pingInfo objectAtIndex:i],
                                                        [pingAdd objectAtIndex:i]]];
        if ([[pingAdd objectAtIndex:i] isEqualToString:kPingOpenServerIP]) {
            [_netPinger runWithHostName:[pingAdd objectAtIndex:i] normalPing:YES];
        } else {
            [_netPinger runWithHostName:[pingAdd objectAtIndex:i] normalPing:YES];
        }
    }
    [self recordStepInfo:@"%@",TRLocalizedString(@"RTNetDiagnosisFinishPing")];
}


#pragma mark -
#pragma mark - netPingDelegate

- (void)appendPingLog:(NSString *)pingLog
{
    [self recordStepInfo:pingLog];
}

- (void)netPingDidEnd
{
    // net
}

#pragma mark - traceRouteDelegate
- (void)appendRouteLog:(NSString *)routeLog
{
    [self recordStepInfo:routeLog];
}

- (void)traceRouteDidEnd
{
//    [self startTRTraceroute];
}

-(void)onFinishAll{
    _isRunning = NO;
    if (self.delegate && [self.delegate respondsToSelector:@selector(netDiagnosisDidEnd:)]) {
        [self.delegate netDiagnosisDidEnd:_logInfo];
    }
}

#pragma mark - onTRTraceroute
//-(void)startTRTraceroute{
//    __weak __typeof(self)weakSelf = self;
//    [weakSelf stopTRTraceroute];
//    [weakSelf recordStepInfo:@"\n------------------------\n开始第二种 TraceRoute"];
//    _trTraceroute = [TRTraceroute startTracerouteWithHost:[_hostAddress firstObject]
//                                    queue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)
//                             stepCallback:^(TRTracerouteRecord *record) {
//                                 [weakSelf recordStepInfo:[record description]];
//                             } finish:^(NSArray<TRTracerouteRecord *> *results, BOOL succeed) {
//                                 [weakSelf recordStepInfo:succeed?@"> Traceroute成功 <":@"> Traceroute失败 <"];
//                                 [weakSelf recordStepInfo:@"\n网络诊断结束\n"];
//                                 [weakSelf onFinishAll];
//                             }];
//}
//
//-(void)stopTRTraceroute{
//    if(_trTraceroute){
//        [_trTraceroute stopTrace];
//    }
//    _trTraceroute = nil;
//}


#pragma mark - connectDelegate
- (void)appendSocketLog:(NSString *)socketLog
{
    [self recordStepInfo:socketLog];
}

- (void)connectDidEnd:(BOOL)success
{
    if (success) {
        _connectSuccess = YES;
    }
}



#pragma mark - common method
- (void)recordStepInfo:(NSString *)stepInfo ,...{
    if(stepInfo!=nil){
        va_list arg_list;
        va_start(arg_list, stepInfo);
        NSString*result = [[NSString alloc]initWithFormat:stepInfo arguments:arg_list];
        va_end(arg_list);
        [self _recordStepInfo:[result copy]];
    }
}

/**
 * 如果调用者实现了stepInfo接口，输出信息
 */
- (void)_recordStepInfo:(NSString *)stepInfo
{
    if (stepInfo == nil) stepInfo = @"";
    [_logInfo appendString:stepInfo];
    [_logInfo appendString:@"\n"];
    if (self.delegate && [self.delegate respondsToSelector:@selector(netDiagnosisStepInfo:)]) {
        [self.delegate netDiagnosisStepInfo:[NSString stringWithFormat:@"%@\n", stepInfo]];
    }
}


/**
 * 获取deviceID
 */
- (NSString *)uniqueAppInstanceIdentifier
{
    NSString *app_uuid = @"";
    CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
    app_uuid = [NSString stringWithString:(__bridge NSString *)uuidString];
    CFRelease(uuidString);
    CFRelease(uuidRef);
    return app_uuid;
}


@end
