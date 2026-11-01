"""Download only the pinned 0.6B 4-bit model; no credentials or global installs."""
import pathlib,urllib.request,hashlib
root=pathlib.Path.home()/'Library/Caches/VoicePaste/EngineEvaluation/model';root.mkdir(parents=True,exist_ok=True)
revision='313d850181767edf09f00a9c289becca70e58cd0'
for name in ['config.json','generation_config.json','merges.txt','model.safetensors','preprocessor_config.json','tokenizer_config.json','vocab.json','chat_template.json']:
 target=root/name
 if target.exists():
  raise SystemExit(f'{target} exists: verify cache before retry; refusing overwrite')
 print(name,flush=True)
 urllib.request.urlretrieve(f'https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/{revision}/{name}',str(target))

actual=hashlib.sha256((root/'model.safetensors').read_bytes()).hexdigest()
assert actual=='70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf',actual
