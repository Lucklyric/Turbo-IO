#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import "../ResearchUI.h"
#import "../Profile.h"
@protocol TIOPreviewProfileSaving
- (void)save;
@end
#import "HomeTabFixture.h"
#import "../NavigationUI.h"
#import "../ManualHUD.h"
#import "../SubtitleHUD.h"
extern UITabBarController *TIOCreateResearchPreview(void);
extern void TIONavRunTransportFixture(void);
extern void TIOProtocolRuntimeFixture(void);
@interface PreviewDelegate:NSObject<UIApplicationDelegate,UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation PreviewDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options{
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{UISceneConfiguration *c=[[UISceneConfiguration alloc]initWithName:@"Preview" sessionRole:session.role];c.delegateClass=PreviewDelegate.class;return c;}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{
    if(![scene isKindOfClass:UIWindowScene.class])return;self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];
    if([NSProcessInfo.processInfo.arguments containsObject:@"--home-tabs"]){self.window.rootViewController=TIOHomeTabFixture();[self.window makeKeyAndVisible];return;}
    UIViewController *host=[UIViewController new];host.view.backgroundColor=UIColor.systemBackgroundColor;self.window.rootViewController=host;[self.window makeKeyAndVisible];
    UIButton *open=[UIButton buttonWithType:UIButtonTypeSystem];[open setTitle:@"打开研究 UI 预览（无眼镜 / 无真实 API）" forState:UIControlStateNormal];open.frame=CGRectMake(15,180,self.window.bounds.size.width-30,60);[open addTarget:self action:@selector(show) forControlEvents:UIControlEventTouchUpInside];[host.view addSubview:open];
    dispatch_async(dispatch_get_main_queue(),^{[self show];});
}
- (void)show{
    UITabBarController *test=TIOCreateResearchTabs(@[[UIViewController new],[UIViewController new],[UIViewController new],[UIViewController new]]);
    for(UINavigationController *nav in test.viewControllers){[nav loadViewIfNeeded];[nav pushViewController:[UIViewController new] animated:NO];[nav pushViewController:[UIViewController new] animated:NO];NSCAssert(nav.viewControllers.count==2,@"Navigation depth cap");[nav popToRootViewControllerAnimated:NO];NSCAssert(nav.viewControllers.count==1,@"Back reaches root");}
    UITabBarController *tabs=TIOCreateResearchPreview();[self.window.rootViewController presentViewController:tabs animated:NO completion:^{
        // Exercise real navigation implementation without hardware actions.
        NSCAssert(tabs.viewControllers.count==4,@"Four roots");
        NSArray *args=NSProcessInfo.processInfo.arguments;NSUInteger tabArg=[args indexOfObject:@"--tab"];
        if(tabArg!=NSNotFound&&tabArg+1<args.count)tabs.selectedIndex=MIN(3,MAX(0,[args[tabArg+1] integerValue]));
        UINavigationController *nav=(id)tabs.selectedViewController;
        if([args containsObject:@"--manual-hud"])[nav pushViewController:TIOManualHUDController() animated:NO];
        if([args containsObject:@"--subtitle-hud"])[nav pushViewController:TIOSubtitleHUDController() animated:NO];
        if([args containsObject:@"--navigation-transport-test"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{TIONavRunTransportFixture();});
        if([args containsObject:@"--protocol-runtime-check"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{TIOProtocolRuntimeFixture();});
        if([args containsObject:@"--navigation"]){UIViewController *page=TIONavigationController();[nav pushViewController:page animated:NO];[page loadViewIfNeeded];if([args containsObject:@"--navigation-fixture"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[page performSelector:NSSelectorFromString(@"startFixture")];});}
        if([args containsObject:@"--navigation-modes-check"]){
            UIViewController *p=nav.topViewController;UISegmentedControl *m=[p valueForKey:@"transportMode"],*travel=[p valueForKey:@"travelMode"];
            NSCAssert(m.numberOfSegments==3&&[[m titleForSegmentAtIndex:1] isEqual:@"Bike"]&&[[m titleForSegmentAtIndex:2] isEqual:@"Drive"],@"Three real transport choices");
            [p performSelector:NSSelectorFromString(@"selectPlace:") withObject:@{@"name":@"模式测试终点",@"lat":@39.9143,@"lon":@116.4112}];
            NSValue *end=[p valueForKey:@"destination"];
            for(NSInteger mode=0;mode<3;mode++){
                m.selectedSegmentIndex=mode;[m sendActionsForControlEvents:UIControlEventValueChanged];
                NSCAssert([[p valueForKey:@"selectedTransport"] integerValue]==mode&&[end isEqual:[p valueForKey:@"destination"]],@"Switch preserves destination");
                travel.selectedSegmentIndex=1;[travel sendActionsForControlEvents:UIControlEventValueChanged];UIButton *b=[p valueForKey:@"beginButton"];
                NSCAssert([b.configuration.title isEqual:[@"Start " stringByAppendingString:[m titleForSegmentAtIndex:mode]]],@"GPS action reflects selected engine");
            }
            [p setValue:@YES forKey:@"active"];[p setValue:@YES forKey:@"routeReady"];m.selectedSegmentIndex=1;[m sendActionsForControlEvents:UIControlEventValueChanged];
            NSCAssert(![[p valueForKey:@"active"] boolValue]&&![[p valueForKey:@"routeReady"] boolValue],@"Ready route invalidated on mode change");
            [p setValue:@YES forKey:@"active"];[p setValue:@YES forKey:@"planning"];[p performSelector:NSSelectorFromString(@"refresh")];NSCAssert(!m.enabled,@"Cannot switch during planning");
            [p setValue:@NO forKey:@"planning"];[p performSelector:NSSelectorFromString(@"refresh")];NSCAssert(!m.enabled,@"Cannot switch while navigating");
            [p performSelector:NSSelectorFromString(@"stopUser")];NSCAssert(m.enabled,@"Stop re-enables selection");
            travel.selectedSegmentIndex=0;[travel sendActionsForControlEvents:UIControlEventValueChanged];
            [@"PASS: three transport segments, selected-mode GPS labels, preserved endpoint, ready-route invalidation, planning/running switch lock and stop recovery. Offline UIKit; no online SDK or lens acceptance." writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/navigation-modes-check.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        if([args containsObject:@"--navigation-workspace-check"]){
            UIViewController *p=nav.topViewController;UIButton *plan=[p valueForKey:@"planButton"],*begin=[p valueForKey:@"beginButton"],*stop=[p valueForKey:@"stopButton"];
            NSCAssert(!plan.enabled&&!begin.enabled&&stop.hidden,@"Idle has no runnable route");
            [p performSelector:NSSelectorFromString(@"selectPlace:") withObject:@{@"name":@"预览测试地点",@"address":@"离线夹具，不是真实算路",@"lat":@39.9143,@"lon":@116.4112}];
            NSCAssert(!plan.enabled,@"Selecting a place cannot bypass SDK consent");
            [p setValue:@YES forKey:@"initialized"];[p performSelector:NSSelectorFromString(@"refresh")];NSCAssert(plan.enabled&&!begin.enabled,@"Selection can plan, cannot begin");
            [p setValue:@YES forKey:@"active"];[p setValue:@YES forKey:@"planning"];[p performSelector:NSSelectorFromString(@"refresh")];NSCAssert(!plan.enabled&&!begin.enabled&&!stop.hidden,@"Planning has stop but no begin");
            [p setValue:@NO forKey:@"planning"];[p setValue:@YES forKey:@"routeReady"];[p performSelector:NSSelectorFromString(@"refresh")];NSCAssert(begin.enabled,@"Route success requires explicit begin");
            [p performSelector:NSSelectorFromString(@"stopUser")];NSCAssert(!begin.enabled&&stop.hidden,@"Stop invalidates route");
            [p setValue:@NO forKey:@"initialized"];
            [@"PASS: idle, consent, place selection, planning, ready and stop UI gates. Synthetic state only; no AMap or lens verification." writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/navigation-workspace-check.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        if([args containsObject:@"--navigation-interaction-check"]){
            UIViewController *p=nav.topViewController;[p setValue:@YES forKey:@"initialized"];
            UISegmentedControl *role=[p valueForKey:@"mapPickRole"];role.selectedSegmentIndex=1;
            // Call the same coordinate handler used by both SDK tap/long-press delegates.
            SEL choose=NSSelectorFromString(@"selectMapCoordinate:");void(*pick)(id,SEL,CLLocationCoordinate2D)=(void *)[p methodForSelector:choose];
            pick(p,choose,CLLocationCoordinate2DMake(39.9087,116.3975));NSCAssert([[p valueForKey:@"hasSimulationStart"] boolValue],@"Map tap can set explicit start");
            NSValue *start=[p valueForKey:@"simulationStart"];role.selectedSegmentIndex=0;pick(p,choose,CLLocationCoordinate2DMake(39.9143,116.4112));
            NSCAssert([start isEqual:[p valueForKey:@"simulationStart"]],@"Selecting destination preserves start");NSCAssert([[p valueForKey:@"hasDestination"] boolValue],@"Single tap path selects destination");
            [p setValue:@YES forKey:@"active"];[p setValue:@YES forKey:@"routeReady"];pick(p,choose,CLLocationCoordinate2DMake(39.92,116.42));
            NSCAssert(![[p valueForKey:@"routeReady"] boolValue]&&![[p valueForKey:@"active"] boolValue],@"Editing ready route invalidates stale plan");
            for(NSString *key in @[@"zoomInButton",@"zoomOutButton",@"centerButton"]){UIButton *b=[p valueForKey:key];NSCAssert([b actionsForTarget:p forControlEvent:UIControlEventTouchUpInside].count==1,@"Map control has real target");}
            [p performSelector:NSSelectorFromString(@"refresh")];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                [p performSelector:NSSelectorFromString(@"searchPlaces")];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    UINavigationController *sheet=(id)p.presentedViewController;UIViewController *picker=sheet.topViewController;NSCAssert(picker!=nil,@"Search entry presents picker");[picker loadViewIfNeeded];
                    UISearchBar *bar=[picker valueForKey:@"bar"];UIButton *submit=[picker valueForKey:@"submitButton"];bar.text=@"";[submit sendActionsForControlEvents:UIControlEventTouchUpInside];NSCAssert([[[picker valueForKey:@"hint"] text] containsString:@"1–120"],@"Empty query visible validation");
                    bar.text=@"北京公园";[submit sendActionsForControlEvents:UIControlEventTouchUpInside];NSCAssert([[[picker valueForKey:@"hint"] text] containsString:@"离线"],@"Button submits to real entry, no invented online results");
                    [picker setValue:@YES forKey:@"searching"];NSUInteger before=[[picker valueForKey:@"generation"] unsignedIntegerValue];UITextField *city=[picker valueForKey:@"city"];city.text=@"上海";[city sendActionsForControlEvents:UIControlEventEditingChanged];NSCAssert(![[picker valueForKey:@"searching"] boolValue]&&[[picker valueForKey:@"generation"] unsignedIntegerValue]>before,@"City edits cancel old request");
                    [picker setValue:@YES forKey:@"searching"];[submit sendActionsForControlEvents:UIControlEventTouchUpInside];NSCAssert(![[picker valueForKey:@"searching"] boolValue]&&[[[picker valueForKey:@"hint"] text] containsString:@"取消"],@"Spinner button cancels");
                    [picker.view layoutIfNeeded];UITableView *table=(id)picker.view;CGRect button=[submit convertRect:submit.bounds toView:table.tableHeaderView];NSCAssert(button.size.height>=44&&CGRectGetMaxY(button)<=table.tableHeaderView.bounds.size.height,@"Submit has visible 44pt target inside header");
                    [@"PASS: map coordinate roles, stable origin, stale route invalidation, wired zoom/center buttons, actual picker presentation, explicit submit/validation/cancel/city invalidation and header layout. Offline simulator; no AMap online or lens claim." writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/navigation-interaction-check.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                });
            });
        }
        if([args containsObject:@"--profile-selftest"]){
            NSDictionary *before=TIOProfile();UITableViewController *root=(id)nav.topViewController;
            [root tableView:root.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:4]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            UIViewController *panel=nav.topViewController;[panel loadViewIfNeeded];
            [(UITextField *)[panel valueForKey:@"nameField"] setText:@"示例用户"];
            [(UITextField *)[panel valueForKey:@"identityField"] setText:@"开发者"];
            [(UITextView *)[panel valueForKey:@"preferences"] setText:@"先给结论"];
            [(id<TIOPreviewProfileSaving>)panel save];
            NSCAssert([TIOProfile()[@"name"] isEqual:@"示例用户"],@"Profile UI saves name");
            NSCAssert([TIOProfilePrompt(TIOProfile()) containsString:@"先给结论"],@"Profile affects prompt");
            NSCAssert(TIOSaveProfile(before),@"Restore preview settings");
            [@"PASS: profile UI save, persisted readback, composed prompt, original preview restored" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/profile-check.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            });
        }
        if([args containsObject:@"--profile"]){UITableViewController *root=(id)nav.topViewController;[root tableView:root.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:4]];}
        if([args containsObject:@"--knowledge"]){UITableViewController *root=(id)nav.topViewController;[root tableView:root.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];}
        NSUInteger detail=[args indexOfObject:@"--detail"];
        if(detail!=NSNotFound&&detail+1<args.count&&tabs.selectedIndex==2){
            NSArray *paths=@[@[@1,@0],@[@1,@1],@[@2,@0],@[@2,@1]];NSUInteger index=MIN(3,MAX(0,[args[detail+1] integerValue]));
            UITableViewController *root=(id)nav.topViewController;NSIndexPath *ip=[NSIndexPath indexPathForRow:[paths[index][1] integerValue] inSection:[paths[index][0] integerValue]];
            [root tableView:root.tableView didSelectRowAtIndexPath:ip];NSCAssert(nav.viewControllers.count==2,@"Library detail reachable");
        }
        if([args containsObject:@"--keyboard"]&&[nav.topViewController isKindOfClass:NSClassFromString(@"TIORecordingTextPanel")])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{UITextView *editor=[nav.topViewController valueForKey:@"editor"];[editor becomeFirstResponder];});
        if([args containsObject:@"--check-close"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{
            TIOCloseResearch(nav);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{NSCAssert(self.window.rootViewController.presentedViewController==nil,@"Close from detail returns to host");[@"PASS: actual detail close returns to host without traversing menus" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/close-check.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];});
        });
        NSLog(@"RESEARCH_UI_PASS: four tabs, depth <= 2, selected %lu",(unsigned long)tabs.selectedIndex);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            NSMutableArray *report=[NSMutableArray new];for(UINavigationController *n in tabs.viewControllers)[report addObject:@{@"title":n.topViewController.title?:@"",@"navigationTitle":n.navigationBar.topItem.title?:@"",@"tab":n.tabBarItem.title?:@"",@"depth":@(n.viewControllers.count)}];
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ui-report.json"] atomically:YES];
        });
    }];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(PreviewDelegate.class));}}
