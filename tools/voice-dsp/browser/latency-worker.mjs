// Deliberate test-only event-loop stalls around the unchanged lab Worker.
import '/original-worker.js'
const initialize=self.onmessage
const ms=Number(new URL(self.location.href).searchParams.get('jitter')??0)
if(![0,12,45,100].includes(ms))throw Error('Unsupported stress injection')
self.onmessage=event=>{
  const port=event.data.port
  const setter=Object.getOwnPropertyDescriptor(MessagePort.prototype,'onmessage').set
  let blocks=0
  Object.defineProperty(port,'onmessage',{set(handler){setter.call(port,message=>{
    if(message.data.type==='block'&&++blocks===8&&ms){
      const until=performance.now()+ms
      while(performance.now()<until){} // Intentional bounded Worker-only CPU stall.
    }
    handler(message)
  })}})
  initialize(event)
}
