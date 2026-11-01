"""Normalized WER/CER plus punctuation sequence distance (not aligned punctuation F1)."""
import collections,json,sys,unicodedata

def normalized(s):
 s=unicodedata.normalize('NFKC',s).casefold().replace('ё','е')
 return ''.join(c if c.isalnum() else ' ' for c in s).split()
def distance(a,b):
 row=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  nxt=[i]
  for j,y in enumerate(b,1): nxt.append(min(nxt[-1]+1,row[j]+1,row[j-1]+(x!=y)))
  row=nxt
 return row[-1]
def marks(s):
 s=unicodedata.normalize('NFKC',s).replace('。','.').replace('、',',')
 return [c for c in s if unicodedata.category(c).startswith('P')]
rows=[]
for line in open(sys.argv[1]):
 if not line.startswith('RESULT '):continue
 r=json.loads(line[7:]); a,b=normalized(r['reference']),normalized(r['text'])
 if r['language']=='zh':a,b=list(''.join(a)),list(''.join(b))
 r['errorCount']=distance(a,b);r['referenceUnits']=len(a)
 r['punctuationEdits']=distance(marks(r['reference']),marks(r['text']))
 r['referencePunctuation']=len(marks(r['reference']))
 r['rtf']=r['seconds']/r['audioSeconds'];rows.append(r)
print(json.dumps(rows,ensure_ascii=False,indent=2))
