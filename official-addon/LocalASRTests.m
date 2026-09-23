#import "LocalASR.h"
#include <assert.h>
#include <math.h>
static NSData *Tone(double seconds,double amplitude){
    NSUInteger n=(NSUInteger)(seconds*16000);NSMutableData *d=[NSMutableData dataWithLength:n*2];int16_t *s=d.mutableBytes;
    for(NSUInteger i=0;i<n;i++)s[i]=(int16_t)(amplitude*sin(2*M_PI*220*i/16000.0));
    return d;
}
int main(void){@autoreleasepool{
    NSData *wav=TIOLocalASRWav(Tone(0.5,1000));
    assert(wav.length==44+16000&&!memcmp(wav.bytes,"RIFF",4)&&!memcmp((const char *)wav.bytes+8,"WAVE",4));
    TIOSpeechSegmenter *seg=[TIOSpeechSegmenter new];NSMutableArray<NSData *> *out=[NSMutableArray new];seg.onSegment=^(NSData *pcm){[out addObject:pcm];};
    // Silence, one second of speech, silence: exactly one sentence with preroll and trailing pause.
    [seg append:Tone(0.5,0)];[seg append:Tone(1.0,3000)];[seg append:Tone(1.0,0)];
    assert(out.count==1);double seconds=out[0].length/32000.0;assert(seconds>1.5&&seconds<2.2);
    // A 0.1 s click is too short to be a sentence.
    [seg append:Tone(0.1,3000)];[seg append:Tone(1.0,0)];assert(out.count==1);
    // Odd-sized chunks still frame correctly, and a sentence never exceeds 15 s.
    NSData *longSpeech=Tone(20,3000);for(NSUInteger i=0;i<longSpeech.length;i+=333)[seg append:[longSpeech subdataWithRange:NSMakeRange(i,MIN(333,longSpeech.length-i))]];
    [seg flush];assert(out.count==3);assert(out[1].length<=15*32000+640);
    // 16 kHz to 24 kHz: 3 output samples per 2 input, continuous across uneven chunks.
    TIOResampler24k *rs=[TIOResampler24k new];NSData *src=Tone(1.0,3000);NSMutableData *dst=[NSMutableData new];
    for(NSUInteger i=0;i<src.length;i+=202)[dst appendData:[rs process:[src subdataWithRange:NSMakeRange(i,MIN(202,src.length-i))]]];
    NSUInteger samples=dst.length/2;assert(samples>=23990&&samples<=24010);
    const int16_t *o=dst.bytes;for(NSUInteger i=1;i<samples;i++)assert(abs(o[i]-o[i-1])<400);
    NSLog(@"PASS: local ASR WAV header, speech segmenter and 24 kHz resampler");
}return 0;}
