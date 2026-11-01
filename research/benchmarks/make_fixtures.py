"""Synthetic fixtures only; never reads user recordings."""
import json, pathlib, subprocess, sys, wave, random, struct
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
rows=[]
for cid,language,voice,text in [
('ru-01','ru','Milena','Привет, это проверка диктовки. Сегодня мы обсудим план работы на неделю.'),
('ru-05','ru','Milena','Скажите, пожалуйста, как пройти к ближайшей станции метро?'),
('ru-08','ru','Milena','Если что-то пойдёт не так, сразу напишите мне, я постараюсь помочь.'),
('en-01','en','Samantha','Please send me the report by the end of the day.'),
('en-04','en','Samantha','Thank you for your help, we could not have done it without you.')]:
 temp=root/(cid+'.aiff')
 subprocess.run(['say','-v',voice,'-o',str(temp),text],check=True)
 subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(temp),str(root/(cid+'.wav'))],check=True)
 temp.unlink();rows.append(dict(id=cid,language=language,text=text))
random.seed(7)
for cid,values in [('silence-5s',[0]*80000),('noise-5s',[int(random.gauss(0,400)) for _ in range(80000)])]:
 with wave.open(str(root/(cid+'.wav')),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(struct.pack('<'+'h'*len(values),*values))
 rows.append(dict(id=cid,language='none',text=''))
for i,text in enumerate(['今天天气很好，我们一起去公园散步吧。','请把这份文件发给我，谢谢你的帮助。','明天下午三点我们开会，请准时参加。'],1):
 cid=f'zh-{i:02d}';temp=root/(cid+'.aiff')
 subprocess.run(['say','-v','Meijia','-o',str(temp),text],check=True)
 subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(temp),str(root/(cid+'.wav'))],check=True)
 temp.unlink();rows.append(dict(id=cid,language='zh',text=text))
random.seed(7)
for base in ['ru-01','en-01','zh-01']:
 with wave.open(str(root/(base+'.wav'))) as w: data=w.readframes(w.getnframes())
 values=struct.unpack('<'+'h'*(len(data)//2),data)
 noisy=[max(-32768,min(32767,int(v*.45+random.gauss(0,800)))) for v in values]
 cid=base+'-synthetic-noise'
 with wave.open(str(root/(cid+'.wav')),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(struct.pack('<'+'h'*len(noisy),*noisy))
 row=next(r for r in rows if r['id']==base);rows.append(dict(row,id=cid))
(root/'manifest.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
for r in rows:
 if r['language']=='none':continue
 with wave.open(str(root/(r['id']+'.wav'))) as w:
  data=w.readframes(w.getnframes())
 samples=struct.unpack('<'+'h'*(len(data)//2),data)
 if len(samples)<16000 or max(map(abs,samples),default=0)<100:
  raise SystemExit(f"Invalid synthetic speech fixture: {r['id']}; install required system voice")
