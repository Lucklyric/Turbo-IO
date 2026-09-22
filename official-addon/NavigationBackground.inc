// Included in TIONavigationPanel; never changes the host's Bluetooth lifecycle.
- (BOOL)navigationLocationAuthorized {
    CLAuthorizationStatus s=self.permission.authorizationStatus;
    return s==kCLAuthorizationStatusAuthorizedAlways || s==kCLAuthorizationStatusAuthorizedWhenInUse;
}
- (BOOL)navigationLocationModeAvailable {
    id modes=[NSBundle.mainBundle objectForInfoDictionaryKey:@"UIBackgroundModes"];
    return [modes isKindOfClass:NSArray.class] && [modes containsObject:@"location"];
}
- (void)endNavigationBackgroundTask {
    self.backgroundEpoch++;
    UIBackgroundTaskIdentifier task=self.navigationBackgroundTask;
    self.navigationBackgroundTask=UIBackgroundTaskInvalid;
    if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];
}
- (void)expireNavigationBackgroundTask:(NSUInteger)epoch {
    if(epoch!=self.backgroundEpoch || self.navigationBackgroundTask==UIBackgroundTaskInvalid)return;
    [self stopUser];
    self.note=@"Background test time for simulated navigation has ended. Return to the foreground and start again. Simulation never stays alive with fake location or silent audio.";
    [self refresh];
}
- (void)background {
    TIONavBackgroundAction action=TIONavBackgroundPolicy(self.navigationStarted,self.fixture,self.simulated,self.backgroundLocationEnabled,[self navigationLocationAuthorized]);
    if(action==TIONavBackgroundIdle)return;
    if(action==TIONavBackgroundStop){[self stopUser];self.note=@"Background navigation requirements not met, so it stopped. Check location permission and the host app's location background mode.";[self refresh];return;}
    if(action==TIONavBackgroundLocation){self.note=@"Live navigation running in the background. Ending navigation turns off background location for this session. Follow the phone map and actual road conditions.";[self refresh];return;}
    if(self.navigationBackgroundTask!=UIBackgroundTaskInvalid)return;
    NSUInteger epoch=++self.backgroundEpoch;__weak typeof(self) weak=self;
    self.navigationBackgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"TurboIO navigation simulation handoff" expirationHandler:^{[weak expireNavigationBackgroundTask:epoch];}];
    if(self.navigationBackgroundTask==UIBackgroundTaskInvalid){[self stopUser];self.note=@"The system did not grant background time for simulation. Please test in the foreground.";[self refresh];return;}
    self.note=@"Short background test of simulated navigation (up to 25 s; the system may end it sooner). For continuous lock-screen navigation, use an authorized live route.";[self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak expireNavigationBackgroundTask:epoch];});
}
- (void)navigationForeground {
    [self endNavigationBackgroundTask];
    if(self.navigationStarted&&!self.simulated&&![self navigationLocationAuthorized]){[self stopUser];self.note=@"Location permission revoked. Navigation stopped.";}
    else if(self.navigationStarted)self.note=self.simulated?@"Simulated navigation continues (foreground)":@"Live navigation continues. You can background the app or lock the screen, but do not force-quit it.";
    [self refresh];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if(manager!=self.permission)return;
    if(self.navigationStarted&&!self.simulated&&![self navigationLocationAuthorized]){
        [self stopUser];self.note=@"Location permission revoked. Navigation and background location for this session stopped.";[self refresh];
    }
}
