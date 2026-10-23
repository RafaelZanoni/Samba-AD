# Samba-AD — Servidor de domínio e arquivos sem licença Windows

> **Para quem é este manual:** para quem já usa um domínio Windows (faz login no
> computador com usuário e senha da empresa, usa "Usuários e Computadores do
> Active Directory", acessa pastas como `\\SERVIDOR\Arquivos`) e quer **reduzir
> custo** trocando parte dessa estrutura por software gratuito (Samba) e
> armazenamento em nuvem (Google Cloud Storage).
>
> Você **não precisa saber Linux**. Todos os comandos estão escritos aqui
> exatamente como devem ser digitados. Basta copiar e colar.

---

## Sumário

1. [O que este projeto faz (em uma página)](#1-o-que-este-projeto-faz-em-uma-página)
2. [Onde está a economia](#2-onde-está-a-economia)
3. [Dicionário: Windows × este projeto](#3-dicionário-windows--este-projeto)
4. [Como fica a estrutura no final](#4-como-fica-a-estrutura-no-final)
5. [Antes de começar: lista de verificação](#5-antes-de-começar-lista-de-verificação)
6. [Ficha de dados do cliente (preencha antes)](#6-ficha-de-dados-do-cliente-preencha-antes)
7. [Noções mínimas: como entrar no servidor e usar os comandos](#7-noções-mínimas-como-entrar-no-servidor-e-usar-os-comandos)
8. [Etapa 1 — Colocar o servidor Samba no domínio (`join-ad.sh`)](#8-etapa-1--colocar-o-servidor-samba-no-domínio-join-adsh)
9. [Etapa 2 — Ligar a pasta da nuvem ao servidor (`setup-bucket.sh`)](#9-etapa-2--ligar-a-pasta-da-nuvem-ao-servidor-setup-bucketsh)
10. [Etapa 3 — Permissões por departamento (`gcs-repositorio.sh`)](#10-etapa-3--permissões-por-departamento-gcs-repositoriosh)
11. [Dia a dia: administrando tudo pelo Windows](#11-dia-a-dia-administrando-tudo-pelo-windows)
12. [Como os funcionários acessam os arquivos](#12-como-os-funcionários-acessam-os-arquivos)
13. [Limitações importantes (leia antes de prometer ao cliente)](#13-limitações-importantes-leia-antes-de-prometer-ao-cliente)
14. [Problemas comuns e como resolver](#14-problemas-comuns-e-como-resolver)
15. [Como desfazer](#15-como-desfazer)
16. [Cola rápida de comandos](#16-cola-rápida-de-comandos)

---

## 1. O que este projeto faz (em uma página)

Este projeto é um conjunto de **3 roteiros automáticos** (chamados de *scripts*).
Cada script faz, sozinho, dezenas de configurações que um técnico Linux levaria
horas para fazer à mão. Eles são executados **em ordem**, uma única vez cada:

| Ordem | Script | O que faz, em português simples | Equivalente no mundo Windows |
|:-:|---|---|---|
| 1 | `join-ad.sh` | Transforma um servidor Linux novo em um **segundo controlador de domínio** da sua empresa. Ele passa a conhecer todos os usuários, senhas e grupos que já existem no seu Windows. | Instalar um novo Windows Server e "promover a controlador de domínio" |
| 2 | `setup-bucket.sh` | Liga uma **pasta na nuvem do Google** a esse servidor e publica essa pasta na rede como um **compartilhamento** (`\\SERVIDOR\gcs`). | Criar uma pasta compartilhada num servidor de arquivos |
| 3 | `gcs-repositorio.sh` | Organiza esse compartilhamento em **pastas por departamento**, com permissões controladas **pelos grupos do Active Directory**. Todos leem tudo; cada departamento só altera a sua pasta. | Configurar a aba "Segurança" (NTFS) de cada pasta |

Depois de instalado, **todo o controle é feito pelo Windows**, na tela que você já
conhece, **"Usuários e Computadores do Active Directory"**. Você cria um grupo
chamado `GCS_Financeiro` e, em até 5 minutos, aparece uma pasta `Financeiro` no
compartilhamento, que só os membros desse grupo podem alterar. Não é preciso entrar no
Linux para o trabalho do dia a dia.

---

## 2. Onde está a economia

| Item | Estrutura tradicional Windows | Com este projeto |
|---|---|---|
| Sistema do servidor | Licença do Windows Server | **Ubuntu Linux: gratuito** |
| Licenças de acesso (CALs) por usuário/dispositivo | Necessárias para cada pessoa que usa o servidor | **Não existem no Samba** |
| Disco do servidor de arquivos | Discos grandes, RAID, troca de discos, backup em fita/HD | **Nuvem do Google**: paga-se só o espaço usado, sem comprar disco |
| Crescimento | Comprar disco novo, migrar dados | Automático: a nuvem cresce sozinha |
| Servidor | Máquina potente para guardar tudo | Máquina modesta: só guarda uma **cópia temporária** (cache) dos arquivos mais usados |

**Atenção aos custos da nuvem** (para não haver surpresa na fatura):

- O Google cobra pelo **espaço armazenado** (por GB/mês).
- Se o servidor **não estiver dentro do Google Cloud** (por exemplo, está no
  escritório do cliente), o Google também cobra pelo **volume de dados baixados**
  da nuvem para o servidor. O cache local (Etapa 2) existe justamente para reduzir
  esse volume: arquivo aberto uma vez fica guardado no servidor e não é baixado de novo.
- Peça ao responsável pela conta Google uma estimativa usando a calculadora de
  preços do Google Cloud antes de migrar grandes volumes.

---

## 3. Dicionário: Windows × este projeto

Termos que aparecem neste manual e nas mensagens dos scripts:

| Termo | O que significa | Você já conhece como… |
|---|---|---|
| **Active Directory (AD)** | O "cadastro central" de usuários, senhas, grupos e computadores da empresa | O mesmo AD de sempre |
| **Controlador de domínio (DC)** | Servidor que guarda o AD e valida o login das pessoas | "O servidor de domínio" |
| **Samba** | Programa gratuito que faz um servidor Linux se comportar como um servidor Windows (domínio e pastas compartilhadas) | Windows Server |
| **Linux / Ubuntu** | O sistema operacional do servidor novo. Ubuntu é a "versão" de Linux usada aqui | Windows |
| **Script** | Arquivo com uma lista de comandos que o computador executa sozinho, em ordem | Um arquivo `.bat` ou `.ps1` |
| **Bucket** | Uma "pasta raiz" de arquivos na nuvem do Google (Google Cloud Storage, ou **GCS**) | Um disco de rede ou um OneDrive da empresa |
| **Share / compartilhamento** | Pasta publicada na rede | `\\SERVIDOR\Pasta` |
| **Cache** | Disco do servidor que guarda cópia dos arquivos usados recentemente para abrir rápido | — |
| **Grupo `GCS_…`** | Grupo do AD cujo nome começa com `GCS_`. Cada um vira uma pasta | Grupo de segurança comum |
| **NetBIOS do domínio** | O nome curto do domínio, que aparece antes da barra no login (`EMPRESA\joao`) | `EMPRESA` |
| **Nome DNS do domínio** | O nome longo do domínio (`empresa.local`, `empresa.com.br`) | — |
| **root / sudo** | O "administrador" do Linux. `sudo` na frente de um comando = "executar como administrador" | "Executar como administrador" |
| **Terminal / SSH** | Janela de texto para enviar comandos a outro computador pela rede | Área de Trabalho Remota, mas só com texto |

---

## 4. Como fica a estrutura no final

```
                      ┌─────────────────────────────────┐
                      │  Nuvem Google (Bucket GCS)      │
                      │  Aqui ficam TODOS os arquivos   │
                      └───────────────▲─────────────────┘
                                      │ internet
┌──────────────────────┐   replica    ┌───────────────┴──────────────────┐
│ DC1 – Windows Server │ ◄──────────► │ DC2 – Servidor Linux com Samba   │
│ (o que já existe)    │  usuários,   │  • 2º controlador de domínio      │
│                      │  senhas,     │  • Compartilhamento \\DC2\gcs      │
│                      │  grupos      │  • Disco de cache (cópia local)  │
└──────────▲───────────┘              └───────────────▲──────────────────┘
           │                                          │
           └──────────── Computadores Windows ────────┘
               (login no domínio + acesso às pastas)
```

Dentro do compartilhamento `\\DC2\gcs`, depois da Etapa 3:

```
\\DC2\gcs
 ├── Financeiro      ← todos leem; só o grupo GCS_Financeiro altera
 ├── RH              ← todos leem; só o grupo GCS_RH altera
 ├── Fotografia      ← todos leem; só o grupo GCS_Fotografia altera
 └── (arquivos soltos na raiz: todos leem; só "Domain Admins" altera)
```

---

## 5. Antes de começar: lista de verificação

Marque cada item. **Não comece se algum estiver faltando.**

### No ambiente atual (Windows)

- [ ] Existe um domínio Active Directory funcionando (o "DC1").
- [ ] Você tem **usuário e senha de um administrador do domínio** (membro de *Domain Admins*).
- [ ] Você sabe o **IP do DC1**.
- [ ] O relógio do DC1 está certo. *(Diferença de mais de 5 minutos entre servidores impede o login.)*
- [ ] Em um computador Windows seu, instale as **Ferramentas de Administração Remota (RSAT)**:
      *Configurações → Aplicativos → Recursos opcionais → Adicionar recurso →
      "RSAT: Ferramentas do Active Directory Domain Services"*. Isso instala a tela
      "Usuários e Computadores do Active Directory".

### O servidor novo (Linux)

- [ ] Uma máquina (física ou virtual) com **Ubuntu Server 24.04 LTS**, recém-instalado.
- [ ] **Dois discos**:
  - Disco 1: o sistema (onde o Ubuntu foi instalado).
  - Disco 2: **vazio**, para o cache. Normalmente aparece como `/dev/sdb`.
    Tamanho sugerido: no mínimo **20 GB por pasta de departamento + 50 GB**.
    *(Ex.: 6 departamentos → pelo menos 170 GB.)*
- [ ] Um **IP fixo livre** na rede para este servidor, e o **gateway** da rede.
- [ ] O servidor consegue acessar a internet (para baixar programas e falar com o Google).
- [ ] Você tem usuário e senha para entrar nesse servidor (criados na instalação do Ubuntu).

### No Google Cloud

- [ ] Um **bucket** já criado (peça ao responsável pela conta Google). Anote o **nome exato**.
- [ ] Uma **conta Google** com permissão de **ler e gravar** nesse bucket
      (papel "Storage Object Admin" ou superior).

---

## 6. Ficha de dados do cliente (preencha antes)

Copie esta tabela num papel ou bloco de notas e preencha. Todas as etapas usam estes dados.

| # | Informação | Exemplo | Onde descobrir | Seu valor |
|:-:|---|---|---|---|
| A | Nome DNS do domínio | `empresa.local` | No Windows do domínio, abra o *Prompt de Comando* e digite `echo %USERDNSDOMAIN%` (use a resposta em minúsculas) | |
| B | Nome NetBIOS do domínio | `EMPRESA` | No *Prompt de Comando*: `echo %USERDOMAIN%` | |
| C | Usuário administrador do domínio | `administrador` | Quem administra o AD | |
| D | Nome do DC1 (Windows existente) | `SRVDC01` | No DC1: *Prompt de Comando* → `hostname` | |
| E | IP do DC1 | `10.10.200.5` | No DC1: *Prompt de Comando* → `ipconfig` | |
| F | Nome do servidor novo (DC2) | `SRVDC02` | Você escolhe. Até 15 letras/números, sem espaço | |
| G | IP fixo do DC2 | `10.10.200.8` | Combine com quem cuida da rede | |
| H | Máscara em "prefixo" | `16` (= 255.255.0.0) ou `24` (= 255.255.255.0) | `ipconfig` mostra a máscara; converta pela tabela abaixo | |
| I | Gateway | `10.10.1.9` | `ipconfig` → "Gateway Padrão" | |
| J | Rede inteira | `10.10.0.0/16` | Início da faixa da rede + `/` + prefixo (H) | |
| K | DNS para internet (encaminhador) | `8.8.8.8` ou IP do DC1 | Normalmente o próprio DC1 ou o DNS do provedor | |
| L | Nome do *site* do AD | `Default-First-Site-Name` | No DC1: *Sites e Serviços do Active Directory* | |
| M | Nome do bucket | `empresa-arquivos` | Responsável pela conta Google | |
| N | Disco de cache | `/dev/sdb` | Etapa 2 explica como confirmar | |

**Conversão de máscara para prefixo:**

| Máscara (`ipconfig`) | Prefixo |
|---|:-:|
| 255.255.255.0 | 24 |
| 255.255.0.0 | 16 |
| 255.0.0.0 | 8 |

---

## 7. Noções mínimas: como entrar no servidor e usar os comandos

Você vai precisar de apenas **4 habilidades**. Treine-as uma vez antes de começar.

### 7.1 Conectar no servidor a partir do Windows

O Windows 10/11 já vem com tudo o que é necessário.

1. Abra o **PowerShell** (botão Iniciar → digite *PowerShell* → Enter).
2. Digite (trocando pelo seu usuário do Ubuntu e o IP atual do servidor):
   ```
   ssh usuario@10.10.200.8
   ```
3. Na primeira vez ele pergunta `Are you sure you want to continue connecting?` → digite `yes` e Enter.
4. Digite a senha. **Nada aparece enquanto você digita, é normal.** Pressione Enter.
5. Você verá algo como `usuario@servidor:~$`. Pronto, você está "dentro" do servidor.

Para sair: digite `exit`.

### 7.2 Copiar os scripts para o servidor

Com o PowerShell **no seu computador** (não dentro do servidor), na pasta onde estão
os arquivos deste projeto:

```
scp join-ad.sh.bak setup-bucket.sh.bak gcs-repositorio.sh usuario@10.10.200.8:~
```

> Prefere arrastar e soltar? Use o programa gratuito **WinSCP**: conecte com o
> mesmo IP, usuário e senha e arraste os arquivos para a pasta do usuário.

Depois, **dentro do servidor**, prepare os arquivos (só uma vez):

```
cp join-ad.sh.bak join-ad.sh
cp setup-bucket.sh.bak setup-bucket.sh
sed -i 's/\r$//' join-ad.sh setup-bucket.sh gcs-repositorio.sh
chmod +x join-ad.sh setup-bucket.sh gcs-repositorio.sh
```

O que essas linhas fazem: criam cópias com o nome certo, corrigem quebras de linha
caso o arquivo tenha passado pelo Bloco de Notas do Windows, e marcam os arquivos como
"executáveis" (como um `.exe`).

### 7.3 Editar um arquivo (o editor `nano`)

```
nano join-ad.sh
```

- Use as **setas do teclado** para andar. O mouse não funciona.
- Apague e digite normalmente.
- **Salvar:** `Ctrl + O`, depois `Enter`.
- **Sair:** `Ctrl + X`.

> ⚠️ **Não edite os scripts no Bloco de Notas do Windows.** Ele altera o final das
> linhas e o script para de funcionar. Se fizer isso por engano, rode de novo o
> comando `sed -i 's/\r$//' ...` do item 7.2.

### 7.4 Ler o resultado

Os scripts mostram mensagens coloridas e com símbolos:

| Aparece | Significa | O que fazer |
|---|---|---|
| `==> Texto` | Começou um passo | Aguardar |
| `✔ Texto` | Passo concluído com sucesso | Nada |
| `! Texto` ou `AVISO:` | Atenção, mas continuou | Ler; normalmente não impede |
| `✘ Texto` ou `ERRO:` | **Parou.** Algo precisa ser corrigido | Ver a [seção 14](#14-problemas-comuns-e-como-resolver) |
| `[s/N]` | Pergunta. `N` maiúsculo = resposta padrão é "não" | Digite `s` e Enter para confirmar |

---

## 8. Etapa 1 — Colocar o servidor Samba no domínio (`join-ad.sh`)

**Objetivo:** o servidor Linux vira um **segundo controlador de domínio** e passa a
ter uma cópia de todos os usuários, senhas e grupos do AD atual.

**Tempo estimado:** 15 a 30 minutos.
**Impacto para os usuários:** nenhum. O DC1 continua funcionando normalmente.

### 8.1 O que o script faz sozinho

1. Dá ao servidor o nome escolhido (F) e o IP fixo (G).
2. Aponta o DNS do servidor para o DC1.
3. Instala o Samba e os programas de autenticação (Kerberos) e de horário (Chrony).
4. Confere se o relógio está certo.
5. Confere se encontra o domínio e pede a **senha do administrador do domínio**.
6. Junta o servidor ao domínio como controlador.
7. Registra o novo servidor no DNS do domínio.
8. Confere se a cópia (replicação) entre DC1 e DC2 está funcionando.

Tudo fica registrado no arquivo `/var/log/join-ad.log`.

### 8.2 Preencher as configurações

```
nano join-ad.sh
```

Altere **somente** o bloco do topo, entre as linhas `CONFIGURACAO DO CLIENTE` e
`NAO EDITAR ABAIXO`. Mantenha as aspas `"` em volta de cada valor.

| Linha no arquivo | Preencha com (da ficha) | Observação |
|---|---|---|
| `DOMAIN="..."` | **A** – nome DNS do domínio, em minúsculas | Ex.: `"empresa.local"` |
| `WORKGROUP="..."` | **B** – NetBIOS do domínio, **em MAIÚSCULAS** | Ex.: `"EMPRESA"` |
| `ADMIN_USER="..."` | **C** – usuário administrador | Só o nome, sem `EMPRESA\` |
| `USE_RFC2307="yes"` | Deixe `yes` | |
| `DC1_HOSTNAME="..."` | **D** | Ex.: `"SRVDC01"` |
| `DC1_IP="..."` | **E** | |
| `DC2_HOSTNAME="..."` | **F** | Ex.: `"SRVDC02"` |
| `DC2_IP="..."` | **G** | |
| `DC2_PREFIX="..."` | **H** | Só o número, ex.: `"24"` |
| `GATEWAY="..."` | **I** | |
| `DNS_FORWARDER="..."` | **K** | Confira se o IP está digitado certo (só números e pontos) |
| `LAN_CIDR="..."` | **J** | Ex.: `"10.10.0.0/16"` |
| `SITE="..."` | **L** | Igual ao que aparece no Windows |
| `IFACE="auto"` | Deixe `auto` | |

Salve (`Ctrl+O`, `Enter`) e saia (`Ctrl+X`).

### 8.3 Executar

```
sudo ./join-ad.sh install
```

Durante a execução:

1. **Pode pedir a senha do Ubuntu** (por causa do `sudo`).
2. **A conexão pode cair** quando o script troca o IP do servidor. Isso é esperado.
   Se acontecer, ele mesmo avisa: reconecte usando o **novo IP (G)** e rode
   **o mesmo comando de novo**. O script continua de onde parou.
3. Se o relógio não estiver sincronizado, pergunta `Continuar mesmo assim? [s/N]`.
   O recomendado é responder `N`, acertar o horário do DC1 e rodar de novo.
4. Pede a **senha do administrador do domínio (C)** — às vezes duas vezes.

### 8.4 Como saber que deu certo

No final aparece:

```
=== OK ===
DC:  SRVDC02.empresa.local
AD:  EMPRESA.LOCAL
```

Confirme também pelo Windows:

- Abra **Usuários e Computadores do Active Directory** → pasta **Domain Controllers**.
  O novo servidor (F) deve aparecer ao lado do DC1.

Para conferir a qualquer momento:

```
sudo ./join-ad.sh status
```

Procure por `Samba DC: active` e, na lista de replicação, **`0 consecutive failure(s)`**.

> 💡 Rodar o script de novo depois de pronto **não estraga nada**: ele percebe que já
> está configurado e só verifica a replicação.

---

## 9. Etapa 2 — Ligar a pasta da nuvem ao servidor (`setup-bucket.sh`)

**Objetivo:** fazer o bucket do Google aparecer como uma pasta no servidor e
publicá-la na rede como `\\SRVDC02\gcs`.

**Tempo estimado:** 10 a 20 minutos.
**Pré-requisito:** Etapa 1 concluída **neste mesmo servidor**.

### 9.1 O que o script faz sozinho

1. Confere se a Etapa 1 foi concluída.
2. Prepara o **disco de cache**: se estiver vazio, formata; se já tiver dados ou
   partições, **recusa e para** (proteção contra apagar algo por engano).
3. Instala os programas do Google (`gcsfuse` e `gcloud`).
4. Faz o **login na conta Google** (você participa, veja 9.4).
5. Testa se a conta consegue acessar o bucket.
6. Liga o bucket à pasta `/mnt/gcs` e configura para religar sozinho a cada reinício.
7. Grava e apaga um arquivo de teste na nuvem.
8. Cria o compartilhamento `gcs` na rede, liberado para **Domain Users**.

Registro em `/var/log/setup-bucket.log`.

### 9.2 Confirmar qual é o disco de cache

```
lsblk
```

Aparece uma lista assim:

```
NAME   SIZE TYPE MOUNTPOINTS
sda     50G disk
├─sda1  49G part /
└─sda2   1G part /boot/efi
sdb    200G disk
```

- O disco com `/` ao lado (aqui, `sda`) é o **sistema**. **Nunca use esse.**
- O disco **sem nada** na coluna da direita e com o tamanho que você reservou (aqui,
  `sdb`) é o de **cache**. O valor para a configuração é `/dev/` + o nome: `/dev/sdb`.

> ⚠️ Se escolher o disco errado e ele estiver vazio, **ele será formatado**. Confira duas vezes.

### 9.3 Preencher as configurações

```
nano setup-bucket.sh
```

Edite **somente** o bloco `CONFIGURACAO DO CLIENTE`:

| Linha | Preencha com | Observação |
|---|---|---|
| `CLIENTE="..."` | Nome do cliente | Só aparece nos relatórios |
| `CACHE_DEVICE="..."` | **N** (ex.: `/dev/sdb`) | Veja 9.2 |
| `CACHE_SIZE_MB="auto"` | Deixe `auto` | Usa 90% do disco de cache |
| `BUCKET_NAME="..."` | **M** | Exatamente como no Google, sem `gs://` |
| `SAMBA_SHARE="gcs"` | Deixe `gcs` | É o nome que aparece na rede. Se mudar, mude também na Etapa 3 |
| `AD_ALLOWED_GROUP="Domain Users"` | Deixe assim | Quem pode acessar o compartilhamento |

### 9.4 Executar

```
sudo ./setup-bucket.sh install
```

**Momento do login no Google** — o script vai mostrar algo como:

```
Go to the following link in your browser, and complete the sign-in prompts:
    https://accounts.google.com/o/oauth2/auth?....
Once finished, enter the verification code provided in your browser:
```

1. **Selecione o link inteiro** com o mouse no PowerShell (ele copia ao soltar o
   botão; se não copiar, clique com o botão direito).
2. Cole no **navegador do seu computador** e entre com a conta Google que tem acesso ao bucket.
3. Autorize. O Google mostra um **código**.
4. Copie o código, volte ao PowerShell, **clique com o botão direito** para colar e tecle Enter.

### 9.5 Como saber que deu certo

No final aparece `=== OK ===` e um resumo com a linha:

```
Share:   \\SRVDC02\gcs
```

Teste num computador Windows do domínio: `Windows + R` → digite `\\SRVDC02\gcs` → Enter.
A pasta deve abrir e mostrar o conteúdo do bucket.

Para conferir depois:

```
sudo ./setup-bucket.sh status
```

Procure `GCSFuse: mounted`, `Share: [gcs]` e `ADC: presente`.

> Nesta etapa, **todos** os usuários do domínio podem ler e alterar tudo no
> compartilhamento. A Etapa 3 organiza as permissões por departamento.

---

## 10. Etapa 3 — Permissões por departamento (`gcs-repositorio.sh`)

**Objetivo:** transformar o compartilhamento em um **repositório organizado**:

| Quem | Pode fazer |
|---|---|
| **Domain Users** (todo mundo) | **Ler** todas as pastas |
| Membros do grupo **`GCS_Nome`** | **Ler e alterar** a pasta `Nome` (criar, editar, apagar arquivos e subpastas) |
| **Domain Admins** | **Tudo**, inclusive criar pastas na raiz e mexer em qualquer pasta |

E, principalmente: **depois de instalado, você gerencia tudo pelo Windows**,
criando grupos e colocando pessoas neles. O servidor confere o AD **a cada 5 minutos**
e ajusta as pastas sozinho.

**Tempo estimado:** 5 minutos.
**Impacto:** no momento da instalação, quem estiver com arquivos abertos no
compartilhamento pode ter erro por alguns segundos. **Faça fora do horário de expediente.**

### 10.1 Preparar os grupos no AD (pelo Windows, antes de instalar)

Abra **Usuários e Computadores do Active Directory** e, para cada departamento:

1. Clique com o botão direito numa unidade organizacional → **Novo → Grupo**.
2. **Nome do grupo:** `GCS_` + nome da pasta. Ex.: `GCS_Financeiro`.
3. **Escopo:** Global. **Tipo:** **Segurança** (não use "Distribuição").
4. Abra o grupo → aba **Membros** → adicione as pessoas que podem alterar a pasta.

**Quer um nome de pasta com espaço ou acento?** (ex.: "Recursos Humanos", "Produção")
O nome do grupo não pode ter acento, então:

1. Crie o grupo com um nome simples, ex.: `GCS_RH`.
2. Abra o grupo → aba **Geral** → campo **Observações** (*Notes*) → escreva
   exatamente o nome da pasta: `Recursos Humanos`.

O campo Observações sempre tem prioridade sobre o nome do grupo.

**Regras para o nome da pasta:**

- Até 100 caracteres.
- Não pode começar com ponto (`.`).
- Não pode conter: `/ \ % $ " ' ` ;`
- Dois grupos não podem gerar a mesma pasta (ex.: `Produção` e `Producao` são
  consideradas iguais). O segundo é ignorado e aparece um aviso.

### 10.2 Preencher as configurações

```
nano gcs-repositorio.sh
```

No bloco `VARIÁVEIS`, perto do topo, altere:

| Linha | Preencha com | Observação |
|---|---|---|
| `DOMAIN="..."` | **B** – NetBIOS, em maiúsculas | Ex.: `"EMPRESA"` |
| `BUCKET="..."` | **M** – mesmo nome usado na Etapa 2 | |
| `SHARE="gcs"` | O mesmo `SAMBA_SHARE` da Etapa 2 | |

As demais linhas podem ficar como estão. As mais úteis, caso precise ajustar:

| Linha | Padrão | Significado |
|---|---|---|
| `GROUP_PREFIX="GCS_"` | `GCS_` | Começo do nome dos grupos que viram pasta |
| `ADMIN_GROUP="Domain Admins"` | | Quem tem controle total |
| `USERS_GROUP="Domain Users"` | | Quem pode ler |
| `FOLDER_CACHE_MB=20000` | 20 GB | Espaço de cache reservado **por pasta** no disco de cache |
| `SYNC_INTERVAL="5min"` | 5 min | De quanto em quanto tempo o servidor confere o AD |

> Se seu AD estiver em inglês, os grupos se chamam `Domain Admins` e `Domain Users`.
> Se estiver em português, podem se chamar `Admins. do domínio` e `Usuários do domínio`.
> Use **exatamente** o nome que aparece no Windows.

### 10.3 Simular antes (não altera nada)

```
sudo ./gcs-repositorio.sh --dry-run
```

Logo no início aparece a lista de pastas que **seriam** criadas:

```
==> Lendo grupos GCS_* no AD (DC local)
  ✔ Financeiro  <-  EMPRESA\GCS_Financeiro (GID 3000012)
  ✔ Recursos Humanos  <-  EMPRESA\GCS_RH (GID 3000015)
```

Confira se todos os departamentos aparecem com o nome certo. O resto do texto é
técnico e pode ser ignorado.

### 10.4 Instalar

```
sudo ./gcs-repositorio.sh --install
```

O script avisa que as pastas serão remontadas e pergunta `Continuar? [s/N]` → digite `s`.

Ao final mostra um resumo:

```
==> Instalado. Gestão a partir de agora pelo AD:
  - Nova pasta:   crie o grupo GCS_<Nome> (Observações = nome da pasta, opcional)
  - Escrita:      membros do grupo GCS_<Nome>
  - Leitura:      EMPRESA\Domain Users (todas as pastas)
  - Total:        EMPRESA\Domain Admins
  - Sincroniza a cada 5min; para forçar: sudo /usr/local/sbin/gcs-repositorio --sync
  - Situação:     sudo /usr/local/sbin/gcs-repositorio --status
```

A partir daqui o script fica instalado no servidor como
`/usr/local/sbin/gcs-repositorio` (sem o `.sh`). Use esse nome nos próximos comandos.

### 10.5 Conferir a situação

```
sudo gcs-repositorio --status
```

Exemplo:

```
==> Raiz: /mnt/gcs  root:Domain Admins 775
  Financeiro                     EMPRESA\GCS_Financeiro       active   root:GCS_Financeiro 775
  Recursos Humanos               EMPRESA\GCS_RH               active   root:GCS_RH 775
```

Cada linha é uma pasta. A coluna `active` indica que está funcionando.
Se aparecer `failed` ou `não montada`, veja a [seção 14](#14-problemas-comuns-e-como-resolver).

---

## 11. Dia a dia: administrando tudo pelo Windows

Todas as tarefas abaixo são feitas em **Usuários e Computadores do Active Directory**,
como você já faz hoje. **Não é preciso entrar no Linux.**

| Quero… | Faça isso no AD | Quando vale |
|---|---|---|
| **Criar uma pasta nova** para um departamento | Crie o grupo de segurança `GCS_NomeDaPasta` (veja 10.1) | Em até 5 minutos |
| **Dar permissão de alterar** a alguém | Adicione a pessoa ao grupo `GCS_…` | Depois que **a pessoa sair e entrar** de novo no Windows |
| **Tirar permissão de alterar** | Remova a pessoa do grupo | Depois que a pessoa sair e entrar de novo |
| **Vários grupos alterando a mesma pasta** | Coloque os outros grupos **como membros** do grupo `GCS_…` | Após sair e entrar |
| **Congelar uma pasta** (ninguém mais altera) | Exclua o grupo `GCS_…`. A pasta e os arquivos **continuam**, mas ficam somente leitura | Em até 5 minutos |
| **Apagar uma pasta de vez** | Primeiro exclua o grupo; depois, logado como Domain Admin, apague a pasta pelo Explorer | — |
| **Renomear uma pasta** | Veja o aviso abaixo | — |
| **Aplicar a mudança agora** sem esperar 5 min | Peça ao técnico para rodar `sudo gcs-repositorio --sync` | Imediato |

> ⚠️ **Renomear não move os arquivos.** Se você mudar o nome do grupo ou o campo
> Observações, o servidor cria uma **pasta nova e vazia** com o nome novo. A pasta
> antiga continua lá, somente leitura, com os arquivos. Um Domain Admin precisa
> **mover os arquivos manualmente** da pasta antiga para a nova pelo Explorer.

> ⚠️ **Não renomeie, apague nem mova as pastas de departamento pelo Explorer.**
> Elas são controladas pelos grupos do AD. Mexa sempre pelo grupo.

---

## 12. Como os funcionários acessam os arquivos

### Abrir uma vez

`Windows + R` → digite `\\SRVDC02\gcs` → Enter.

### Deixar fixo como uma letra de unidade (ex.: `G:`)

1. Abra o **Explorador de Arquivos** → clique com o botão direito em **Este Computador**
   → **Mapear unidade de rede**.
2. **Unidade:** escolha uma letra (ex.: `G:`).
3. **Pasta:** `\\SRVDC02\gcs`.
4. Marque **Reconectar ao entrar** → **Concluir**.

Para muitos computadores, o administrador pode fazer isso por GPO (*Configuração do
Usuário → Preferências → Configurações do Windows → Mapeamentos de unidade*) no DC1.

### O que o usuário vai notar

- **Primeira abertura de um arquivo** pode demorar um pouco mais (ele vem da nuvem).
  Nas próximas vezes é rápido (vem do cache).
- Tentar salvar numa pasta de outro departamento dá **"Acesso negado"**. Isso é o esperado.
- A aba **Segurança** nas propriedades das pastas **não é usada**. As permissões vêm
  só dos grupos `GCS_…`.

---

## 13. Limitações importantes (leia antes de prometer ao cliente)

Seja transparente com o cliente sobre o que esta solução **não** faz:

1. **Não desliga o Windows Server sozinho.** O script adiciona o Samba como
   **segundo** controlador. O DC1 Windows continua sendo o principal. Desligar o DC1
   exige passos adicionais (transferência das funções FSMO, revisão de DNS/DHCP,
   GPOs) que **não estão** neste projeto e devem ser feitos por um especialista.
2. **GPOs e scripts de logon não são copiados automaticamente entre DC1 e DC2**
   (o Samba não replica a pasta SYSVOL). Se o cliente usa GPOs, isso precisa de
   tratamento à parte.
3. **Não serve para arquivos abertos por várias pessoas ao mesmo tempo.** Não
   coloque nesse compartilhamento: bancos de dados (Access, sistemas ERP/contábeis),
   arquivos `.pst` do Outlook, planilhas editadas simultaneamente. Se duas pessoas
   salvarem o mesmo arquivo, **vale a última gravação**. Ideal para: documentos,
   fotos, PDFs, materiais, arquivo morto.
4. **Não há lixeira de rede.** Arquivo apagado no compartilhamento é apagado da
   nuvem. Para ter recuperação, peça ao responsável pelo Google Cloud para ativar o
   **versionamento** ou a **exclusão reversível** (*soft delete*) do bucket.
5. **Renomear ou mover pastas muito grandes é lento**, porque na nuvem cada arquivo
   é copiado individualmente. Pastas acima de 200 mil arquivos não podem ser
   renomeadas pelo compartilhamento.
6. **Permissões são por pasta de departamento**, não por arquivo ou subpasta.
   Quem pode alterar a pasta `Financeiro` pode alterar tudo dentro dela.
7. **Precisa de internet.** Sem conexão, só os arquivos que já estão no cache
   ficam acessíveis, e gravações falham.

---

## 14. Problemas comuns e como resolver

### Gerais

| Mensagem / sintoma | Causa provável | Solução |
|---|---|---|
| `Rode como root (sudo)` / `Execute com sudo` | Esqueceu o `sudo` | Repita o comando com `sudo` na frente |
| `Permission denied` ao rodar `./script.sh` | Arquivo sem permissão de execução | `chmod +x nome-do-script.sh` |
| `$'\r': command not found` ou erros estranhos na linha 1 | Arquivo editado no Bloco de Notas | `sed -i 's/\r$//' nome-do-script.sh` |
| `No such file or directory` | Está em outra pasta ou nome digitado errado | Digite `ls` para ver os arquivos e confira o nome |

### Etapa 1 — `join-ad.sh`

| Mensagem | Causa provável | Solução |
|---|---|---|
| Conexão SSH caiu | O script trocou o IP | Reconecte com o IP novo (G) e rode de novo |
| `SRV Kerberos do dominio nao resolve` | O servidor não acha o domínio no DNS | Confira `DOMAIN` e `DC1_IP`. Teste do servidor: `ping IP-do-DC1` |
| `... nao resolve para ...` | Nome ou IP do DC1 errados | Confira `DC1_HOSTNAME` e `DC1_IP` |
| `Falha no kinit` | Senha ou usuário do administrador errados, ou relógio fora | Confira `ADMIN_USER`; acerte a hora do DC1 |
| `Chrony ainda nao informou...` | Relógio não sincronizou | Verifique se o servidor acessa a internet; acerte a hora do DC1 |
| `Replicacao AD apresenta falhas` | DC1 e DC2 não estão conversando | Aguarde 15 minutos e rode `sudo ./join-ad.sh status`. Se continuar, verifique firewall entre os servidores |
| `Workgroup atual '...' diferente de '...'` | `WORKGROUP` não está em maiúsculas ou está errado | Corrija para o NetBIOS em maiúsculas (B) |

### Etapa 2 — `setup-bucket.sh`

| Mensagem | Causa provável | Solução |
|---|---|---|
| `Rode primeiro o join-ad.sh` | A Etapa 1 não foi concluída | Conclua a Etapa 1 |
| `... nao existe ou nao e block device` | Disco de cache errado | Confira com `lsblk` (seção 9.2) |
| `... pertence ao mesmo disco da raiz` | Você indicou o disco do sistema | Use o **segundo** disco |
| `... possui particoes` / `possui assinaturas` | O disco não está vazio | Confirme que não tem nada importante e peça a um técnico para limpá-lo |
| `Credencial Google recusada` | Login do Google falhou ou expirou | `sudo ./setup-bucket.sh relogin` |
| `Conta sem permissao em gs://...` | A conta Google não tem acesso ao bucket | Peça ao responsável do Google Cloud o papel *Storage Object Admin* no bucket |
| `Bucket gs://... nao existe` | Nome do bucket errado | Confira `BUCKET_NAME` (sem `gs://`) |
| Arquivos sumiram / pasta vazia de repente | Credencial do Google expirou | `sudo ./setup-bucket.sh relogin` |

### Etapa 3 — `gcs-repositorio.sh`

| Mensagem | Causa provável | Solução |
|---|---|---|
| `Grupo 'EMPRESA\Domain Admins' não encontrado` | `DOMAIN` errado ou AD em português | Confira `DOMAIN` e os nomes `ADMIN_GROUP`/`USERS_GROUP` (seção 10.2) |
| `Serviço gcsfuse-... não encontrado` | Etapa 2 não executada, ou feita com uma versão diferente | Procure o técnico responsável pelo projeto |
| `Credencial não encontrada` | Idem | Procure o técnico responsável pelo projeto |
| `nome de pasta inválido` | Caractere proibido no nome ou nas Observações | Ajuste o grupo no AD (regras em 10.1) |
| `já usada por outro grupo` | Dois grupos geram o mesmo nome de pasta | Renomeie um deles |
| `Nenhum grupo GCS_* encontrado` | Os grupos ainda não foram criados ou têm outro prefixo | Crie os grupos (10.1) |
| Pasta nova não apareceu | Ainda não passaram 5 minutos | Aguarde ou rode `sudo gcs-repositorio --sync` |
| Pessoa adicionada ao grupo ainda recebe "Acesso negado" | A sessão dela ainda é a antiga | A pessoa deve **sair do Windows e entrar de novo** |
| Pasta aparece como `failed` / `não montada` no `--status` | Erro ao ligar a pasta à nuvem | Rode `sudo gcs-repositorio --sync`. Se persistir, envie ao técnico a saída do comando indicado na mensagem (`journalctl -u ...`) |
| `Outra sincronização em andamento` | A sincronização automática estava rodando | Aguarde 1 minuto e repita |

### Onde estão os registros (para enviar ao suporte)

| Etapa | Comando para ver |
|---|---|
| 1 | `sudo less /var/log/join-ad.log` |
| 2 | `sudo less /var/log/setup-bucket.log` |
| 3 | `sudo journalctl -u gcs-repositorio-sync -n 100` |

Dentro do `less`: setas para rolar, `q` para sair.

---

## 15. Como desfazer

### Desfazer a Etapa 3 (volta ao compartilhamento simples da Etapa 2)

```
sudo gcs-repositorio --remove
```

- Pergunta se deve remover as pastas por departamento → `s`.
- Pergunta se deve restaurar a configuração antiga do Samba → `s`.
- **Nenhum arquivo da nuvem é apagado.** Só as regras de permissão são removidas.

### Etapas 1 e 2

Não há desfazer automático. Para remover o servidor do domínio, peça a um técnico
para rebaixá-lo (`samba-tool domain demote`) **antes** de desligar a máquina; caso
contrário, o DC1 continuará tentando replicar com ele.

---

## 16. Cola rápida de comandos

Imprima esta parte e deixe ao lado do computador.

```
# Entrar no servidor (no PowerShell do seu computador)
ssh usuario@IP-DO-SERVIDOR

# ---------- Instalação (uma vez, nesta ordem) ----------
sudo ./join-ad.sh install
sudo ./setup-bucket.sh install
sudo ./gcs-repositorio.sh --dry-run      # simula
sudo ./gcs-repositorio.sh --install      # instala

# ---------- Verificar se está tudo bem ----------
sudo ./join-ad.sh status                 # domínio e replicação
sudo ./setup-bucket.sh status            # nuvem e compartilhamento
sudo gcs-repositorio --status            # pastas por departamento

# ---------- Manutenção ----------
sudo gcs-repositorio --sync              # aplica mudanças do AD agora
sudo ./setup-bucket.sh relogin           # refaz o login no Google

# ---------- Desfazer a Etapa 3 ----------
sudo gcs-repositorio --remove

# Sair do servidor
exit
```
