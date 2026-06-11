# RUNBOOK — capturar evidência da falha de readiness do Ingestor (debug-06c)

**Objetivo:** capturar, no nó que falhar, a evidência que decide o mecanismo da
falha intermitente do passo `06-start-ingest-server.sh`
(`Ingestor Server failed to become ready after Ns`) e enviá-la **via git** para
análise. A comunicação é só por git (sem copiar texto do cluster).

> Status da investigação: falha é **dependente do nó/run (alocação Slurm)**, NÃO
> é mudança de código. Teoria do IPv6 **refutada** por sondas-irmãs no mesmo nó.
> Mecanismo ainda em aberto. **Não commitar fix especulativo** — só evidência.
> Coletor pronto: `diag-ingestor.sh` (commits 6a1a7d4 + 179215e). Este runbook
> foi validado por subagente em 2026-06-11 (corrige 6 pontos do rascunho).

---

## O que decide o caso (ler antes de rodar)

A janela de espera do 06 é `INGESTOR_READY_ATTEMPTS` (default **90**) × 2s =
**180s**. A sonda é `curl -s http://localhost:8082/health`; o uvicorn faz bind em
`--host 0.0.0.0 --port 8082`. Os três desfechos possíveis:

- **`ss` sem listener a janela toda + ambos curls falham** → socket nunca subiu
  na janela (cold-start/stall; suspeito nº1 = bind-overlay do venv sobre Lustre).
- **listener só em `[::]:8082` + `localhost` rc=7 + `127.0.0.1` code=200** →
  seria IPv6 (improvável; refutado antes, mas confirmar).
- **listener em `0.0.0.0:8082` + ambos curls 200 dentro da janela** → a sonda
  *deveria* ter passado; o log do run que falhou era provavelmente de OUTRO run
  (truncado/sem timestamp) — comparar mtimes.

---

## Procedimento (rodar no **LOGIN node**, exceto onde indicado)

```bash
# ===== STEP A: ambiente + submit + capturar Job ID e NÓ =====
source ~/rag/deploy/singularity/run/cluster-config.sh   # exporta RAG_BASE_DIR etc.

cd ~/rag/deploy/singularity/run
./submit.sh                                  # anote "Job ID : <id>" do banner
JID=<COLE_O_JOB_ID_DO_BANNER>

# o nó só é atribuído quando o job sai de PENDING -> faça poll até preencher:
until NODE=$(squeue -h -j "$JID" -o "%N"); [ -n "$NODE" ]; do echo "aguardando nó..."; sleep 5; done
echo "JID=$JID  NODE=$NODE"

# ===== derivar o diretório de logs do ingestor =====
# (.current_exec é escrito pelo passo 01 — NÃO precisa esperar o banner READY,
#  que só imprime depois do [9/9])
EXEC=$(cat "$RAG_BASE_DIR/sessions/$USER/.current_exec")
LOGS="$EXEC/logs"
echo "LOGS=$LOGS"
mkdir -p ~/rag/deploy/singularity/scripts/import_logs/debug-06c

# ===== STEP B: subir o coletor no MESMO nó AGORA (cobre 04-wait + 06) =====
# Lance já após o nó ser atribuído — NÃO espere ver [6/9] no tail, ou perde o
# first-LISTEN/first-200. --duration 2400 (40min) cobre a janela inteira.
# Deixe rodando (terminal dedicado); ele para sozinho 15s após o 1º 200 estável.
# Ctrl-C ainda escreve o relatório completo (trap).
srun --overlap --jobid="$JID" -w "$NODE" \
  bash ~/rag/deploy/singularity/scripts/diag-ingestor.sh --logs "$LOGS" --duration 2400
```

```bash
# ===== STEP C (SEGUNDO terminal, durante/logo após o [6/9]): sonda decisiva =====
# Usa o $? do shell para o exit code (portável p/ curl antigo do compute node;
# %{exitcode} no -w exige curl recente e pode não existir no nó).
srun --overlap --jobid="$JID" -w "$NODE" bash -c '
  echo "== resolução de nomes =="
  getent hosts localhost
  getent hosts ip6-localhost
  grep -E "127\.0\.0\.1|::1|localhost" /etc/hosts
  echo "== listener (com PID) =="
  ss -ltnp "sport = :8082"
  echo "== probes (rc do shell: 7=conn refused  28=timeout  6=DNS  0=ok) =="
  curl -sS -o /dev/null -w "localhost  code=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 5 http://localhost:8082/health; echo "  rc=$?"
  curl -sS -o /dev/null -w "127.0.0.1  code=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 5 http://127.0.0.1:8082/health; echo "  rc=$?"
  curl -sS -o /dev/null -w "[::1]      code=%{http_code} ip=%{remote_ip} t=%{time_total}\n" --max-time 5 http://[::1]:8082/health; echo "  rc=$?"
'
```

```bash
# ===== STEP D: commitar evidência DO LOGIN node (compute não tem outbound) =====
cd ~/rag
# O diag-ingestor.sh já copiou o relatório .out + ingestor-server-<node>.log para
# debug-06c/ no finalize(). Some o output do job Slurm p/ contexto completo:
cp "$RAG_BASE_DIR/sessions/$USER/rag-setup-${JID}.out" \
   deploy/singularity/scripts/import_logs/debug-06c/ 2>/dev/null || true
# Fallback do log do app, caso o coletor tenha sido interrompido antes do finalize:
cp "$LOGS/ingestor-server.log" \
   deploy/singularity/scripts/import_logs/debug-06c/ingestor-server-${NODE}.log 2>/dev/null || true

git add deploy/singularity/scripts/import_logs/debug-06c/
git commit -m "logs: debug-06c ingestor readiness evidence ($NODE, job $JID)"
git push
```

Depois do `git push`, me avise (aqui no chat: "subi o debug-06c") que eu puxo,
leio o relatório e decido o fix de verdade conforme o desfecho acima.

---

## Notas de validação (por que o procedimento é assim)

1. `NODE` precisa de **poll** — `squeue -o %N` vem vazio enquanto o job está PENDING.
2. `LOGS` **não** sai do banner READY (que só imprime após o [9/9]) — vem do
   `.current_exec` escrito pelo passo 01.
3. STEP C usa `$?` do shell, não `%{exitcode}`, por portabilidade do curl no nó.
4. `debug-06c/` não existe ainda no repo — `mkdir -p` antes de `git add`.
5. `.gitignore`: sob `import_logs/**` só sobem `*.log`/`*.out`/`*.err`. O relatório
   do coletor é `ingestor-diag-<node>-<job>.out` → **commitável**. `.txt` seria ignorado.
6. `git push` **só do login node** (compute tem outbound bloqueado por FortiGate).

O coletor (`diag-ingestor.sh`) já captura no `finalize()`: `ss -ltnp` final,
`/proc/net/tcp` e `/proc/net/tcp6` (porta 1F92), `ps` de uvicorn/singularity,
família do bind no 1º LISTEN, first-200, mtime + linha "Uvicorn running" do log.
O STEP C é o backup one-shot caso o coletor não tenha sido anexado a tempo.
