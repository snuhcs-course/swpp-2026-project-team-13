"""Validate original piano asset bytes and acoustic signal properties offline."""
import hashlib
import json
import math
from pathlib import Path
import struct
import unittest

ROOT=Path(__file__).resolve().parents[1]
RESOURCES=ROOT/"frontend/IPadApp/IPadApp/Resources"

def chunks(data,start,end):
    while start+8<=end:
        name=data[start:start+4]
        length=struct.unpack_from("<I",data,start+4)[0]
        yield name,start+8,start+8+length
        start+=8+length+(length%2)

class AudioAssetTests(unittest.TestCase):
    def test_new_bank_identity_pcm_tuning_and_decay(self):
        profile=json.loads((RESOURCES/"instrument-profile-v2.json").read_text(encoding="utf-8"))
        data=(RESOURCES/profile["resource"]).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),profile["sha256"])
        self.assertEqual(len(data),profile["size_bytes"])
        self.assertEqual(data[:4],b"RIFF");self.assertEqual(data[8:12],b"sfbk")
        parts={}
        for tag,start,end in chunks(data,12,len(data)):
            if tag==b"LIST":
                for child,a,b in chunks(data,start+4,end):
                    parts[child]=data[a:b]
        headers=parts[b"shdr"]
        self.assertEqual(len(headers)//46,38)  # 37 notes and EOS
        _,start,end,_,_,rate,key,_,_,_=struct.unpack_from("<20sIIIIIBbHH",headers,(69-48)*46)
        self.assertEqual((rate,key),(22050,69))
        pcm=struct.unpack("<"+"h"*(end-start),parts[b"smpl"][2*start:2*end])
        self.assertLess(max(abs(x) for x in pcm),32767)
        def energy(a,b):
            return sum(x*x for x in pcm[int(a*rate):int(b*rate)])/(int((b-a)*rate))
        self.assertGreater(energy(0.03,0.15),energy(2,2.5)*20)
        window=pcm[int(0.1*rate):int(0.5*rate)]
        def power(hz):
            re=sum(x*math.cos(2*math.pi*hz*i/rate) for i,x in enumerate(window))
            im=sum(x*math.sin(2*math.pi*hz*i/rate) for i,x in enumerate(window))
            return re*re+im*im
        dominant=max(range(435,446),key=power)
        self.assertLessEqual(abs(dominant-440),1)
        self.assertGreater(power(880),power(1000)*100)

if __name__=="__main__":
    unittest.main()
