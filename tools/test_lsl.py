from pylsl import StreamInfo, StreamOutlet
import time, random

info = StreamInfo('TestEEG', 'EEG', 8, 250, 'float32', 'myuid34234')
outlet = StreamOutlet(info)

while True:
    sample = [random.random() for _ in range(8)]
    outlet.push_sample(sample)
    time.sleep(1.0/250)