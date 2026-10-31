// Bounded owned-ABI checks under fatal sanitizers; no devices or speaker output.
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int fg_new(double,double);
int fg_process(int);
int fg_finish(void);
void fg_close(void);
float *fg_input(void);
float *fg_output(void);
float *fg_feature_input(void);
float *fg_feature_output(void);
static void *watch(void *unused) {
  (void)unused;
  for (;;) { char byte; const ssize_t n=read(0,&byte,1); if (!n || (n<0&&errno!=EINTR)) _Exit(72); }
}
int main(void) {
  pthread_t thread; assert(!pthread_create(&thread,NULL,watch,NULL)); assert(!pthread_detach(thread));
  assert(!fg_new(NAN,1)); assert(!fg_new(1,.8));
  float reference[9600],partitioned[9600];
  for (int profile=0;profile<3;++profile) {
    const double p=profile==0?0:profile==1?-1:1, s=profile==0?1:profile==1?.8:1.25;
    for (int frames=1;frames<=2;++frames) {
      assert(fg_new(p,s));
      assert(fg_process(479)<0); // Invalid shape consumes nothing.
      memset(fg_input(),0,960*sizeof(float));
      int count=fg_process(frames*480); assert(count>=0);
      for (int i=0;i<count;++i) assert(isfinite(fg_output()[i])&&fabsf(fg_output()[i])<.001f);
      const int tail=fg_finish(); assert(tail>=0&&count+tail==frames*480);
      for (int i=0;i<tail;++i) assert(isfinite(fg_output()[i])&&fabsf(fg_output()[i])<.001f);
      fg_close();
    }
    for (int packet=480;packet<=960;packet+=480) {
      assert(fg_new(p,s)==1);
      int count=0;
      for (int start=0;start<9600;start+=packet) {
        for (int i=0;i<packet;++i) fg_input()[i]=.1f*sinf((start+i)*.04f);
        const int n=fg_process(packet); assert(n>=0&&count+n<=9600);
        memcpy((packet==480?reference:partitioned)+count,fg_output(),n*sizeof(float)); count+=n;
      }
      const int n=fg_finish(); assert(n>=0&&count+n==9600);
      memcpy((packet==480?reference:partitioned)+count,fg_output(),n*sizeof(float));
      assert(fg_finish()<0); assert(fg_process(480)<0);
      fg_close();
      for (int i=0;i<960;++i) assert(fg_input()[i]==0);
      for (int i=0;i<2048;++i) assert(fg_output()[i]==0);
      for (int i=0;i<20;++i) assert(fg_feature_input()[i]==0&&fg_feature_output()[i]==0);
    }
    assert(!memcmp(reference,partitioned,sizeof(reference)));
    for (int i=0;i<9600;++i) assert(isfinite(reference[i])&&fabsf(reference[i])<1);
  }
  assert(fg_new(-1,.8)); fg_input()[0]=NAN;
  assert(fg_process(480)<0); fg_input()[0]=0; assert(fg_process(480)<0);
  fg_close();
  return 0;
}
