import {DspBridge} from "../../randos/voice/dsp_bridge"
class LabDspBridge extends DspBridge { constructor(options) { super(options, true) } }
registerProcessor("randos-lab-dsp-bridge", LabDspBridge)
