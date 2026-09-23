#import "ResearchCatalog.h"
static NSDictionary *Row(NSString *key,NSString *title,NSString *icon,NSInteger section,NSInteger row){return @{@"key":key,@"title":title,@"icon":icon,@"section":@(section),@"row":@(row)};}
NSArray<NSDictionary *> *TIOResearchSections(NSString *page){
    if([page isEqual:@"model"])return @[
        @{@"title":@"Custom Agent Controls",@"rows":@[Row(@"agent",@"Execution Agent",@"cpu",-2,0),Row(@"knowledge",@"Knowledge Base & Sources",@"books.vertical",-2,1)]},
        @{@"title":@"Answer Mode",@"rows":@[Row(@"mode",@"Current Answer Mode",@"square.stack.3d.up",0,0)]},
        @{@"title":@"Own Model",@"rows":@[Row(@"api",@"Endpoint & API Key",@"cube",0,1),Row(@"thinking",@"Disable Deep Thinking",@"bolt",0,3),Row(@"effort",@"Reasoning Effort · OpenAI",@"gauge.medium",-6,0)]},
        @{@"title":@"Tools",@"rows":@[Row(@"tools",@"Model Tools",@"wrench.and.screwdriver",0,11)]},
        @{@"title":@"Voice & Context",@"rows":@[Row(@"exit",@"Voice Exit",@"waveform",0,6),Row(@"prompt",@"Profile & Prompt",@"text.bubble",0,5),Row(@"history",@"Current Chat Context",@"clock.arrow.circlepath",0,4)]}];
    if([page isEqual:@"library"])return @[
        @{@"title":@"Maps & Glasses Navigation",@"rows":@[Row(@"navigation",@"Walking / Cycling / Driving Navigation",@"map",-3,0)]},
        @{@"title":@"Recordings & Summaries",@"rows":@[Row(@"recordings",@"Recordings & File Sharing",@"waveform",-1,0),Row(@"summary",@"Transcript Summary",@"text.badge.star",-1,1)]},
        @{@"title":@"Lifelog",@"rows":@[Row(@"lifelogText",@"Saved Text",@"doc.text",-1,2),Row(@"lifelogAudio",@"Audio Saving & Sharing",@"waveform.circle",-1,3),Row(@"capture",@"Save Future Final Text",@"square.and.arrow.down",1,0),Row(@"archive",@"Export Text Archive",@"square.and.arrow.up",1,1)]}];
    if([page isEqual:@"diagnostics"])return @[
#if TIO_OTA_RESEARCH_ENABLED
#if TIO_NATIVE_NAV
        @{@"title":@"TNV1 Research Firmware · Bricking Risk",@"rows":@[Row(@"experimentalOTA",@"TNV1 Navigation Firmware · Locked by Default",@"exclamationmark.shield",-4,0),Row(@"displayPhone",@"Turbo Display · Image Transfer Test",@"rectangle.connected.to.line.below",-4,1)]},
#else
        @{@"title":@"High-Risk Firmware Tests · Not for Daily Use",@"rows":@[Row(@"experimentalOTA",@"R3 Test Build · Read the Risks First",@"exclamationmark.shield",-4,0)]},
#endif
#endif
        @{@"title":@"Experiments",@"rows":@[Row(@"localListen",@"Local Listen · Experimental",@"ear",-7,0)]},
        @{@"title":@"Runtime Status",@"rows":@[Row(@"status",@"Compatibility & Callbacks",@"checkmark.shield",2,0)]},
        @{@"title":@"Manual Tests",@"rows":@[Row(@"apiTest",@"Test Model Endpoint",@"bubble.left.and.bubble.right",0,2),Row(@"todoTest",@"To-dos Protocol Check",@"checklist",0,10)]}];
    return @[];
}
