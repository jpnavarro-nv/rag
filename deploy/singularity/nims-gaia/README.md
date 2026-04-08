# NIM LLM Standalone — GAIA Cluster

Scripts para rodar NVIDIA NIM LLMs no cluster GAIA (4x A100 80GB) via Singularity.

## Dependencias

- Singularity
- Python 3 com `requests` (`pip install requests`)
- NGC API key com acesso a NIM containers

## Quick Start

```bash
export NGC_API_KEY="nvapi-..."
export NIM_BASE_DIR="/path/to/nim-workdir"

./build-nim-images.sh                       # pull das imagens SIF (uma vez)
./run-nim.sh                                # inicia o modelo (default: nemotron3-120b)
python run_inference.py "Sua pergunta aqui" # inferencia streaming
```

## Modelos

| Key | Modelo | Arquitetura | Params |
|-----|--------|-------------|--------|
| `nemotron-49b` | Nemotron Super 49B v1.5 | Dense | 49B |
| `qwen3-122b` | Qwen 3.5 122B-A10B | MoE (10B ativos) | 122B |
| `gpt-oss-120b` | GPT-OSS 120B | MoE | 120B |
| `nemotron3-120b` | Nemotron-3 Super 120B-A12B | MoE (12B ativos) | 120B |

Todos rodam nas 4 GPUs com perfil de menor latencia (auto-selecionado pelo NIM).

## Uso

```bash
./run-nim.sh --list               # lista modelos disponiveis
./run-nim.sh gpt-oss-120b        # inicia modelo especifico
./run-nim.sh                      # default: nemotron3-120b
LLM_GPU_ID=0,1 ./run-nim.sh nemotron-49b   # override de GPUs

python run_inference.py --list    # lista modelos suportados
python run_inference.py "pergunta" > resposta.txt  # piping funciona
```

Parar o modelo:

```bash
kill $(cat $NIM_BASE_DIR/llm-session/pids/nim-llm.pid)
```

## Troubleshooting

**NIM morre durante startup** — verificar log:
```bash
tail -50 $NIM_BASE_DIR/llm-session/logs/<model-key>.log
```
Causas comuns: GPU memory insuficiente, cache corrompido (`rm -rf $NIM_BASE_DIR/models/<key>-cache`).

**Porta em uso** — usar porta alternativa:
```bash
LLM_PORT=9000 ./run-nim.sh
```

**"cannot connect to NIM"** — o modelo ainda esta carregando. Aguardar `run-nim.sh` imprimir "is serving".
