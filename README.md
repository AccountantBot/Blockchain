# Accountant — Smart Contracts 

## Visão Geral

O módulo **`contracts`** do projeto *Accountant* implementa o **núcleo on-chain** do sistema de rateio financeiro da plataforma — um **coordenador de splits sem custódia** que permite que várias pessoas dividam pagamentos entre si sem depender de intermediários.

---

## Objetivo

Permitir que grupos de usuários **criem, assinem e liquidem** rateios (splits) com tokens ERC-20, de forma:

* **Descentralizada** — liquidação é feita on-chain via smart contract.
* **Sem custódia** — o contrato não segura fundos, apenas movimenta com permissão (allowance).
* **Auditável** — todos os dados (participantes, valores, hashes) ficam gravados on-chain.
* **Compatível com UX web2.5** — participantes assinam aprovações via **EIP-712** off-chain e a API executa a liquidação.

---

## Arquitetura Técnica

```text
accountant/
├── contracts/           # Módulo Foundry (Solidity)
│   ├── src/
│   │   └── SplitCoordinator.sol
│   ├── script/
│   │   └── Deploy.s.sol
│   ├── test/
│   │   └── SplitCoordinator.t.sol  (em progresso)
│   ├── foundry.toml
│   ├── remappings.txt
│   └── lib/
│       ├── forge-std/
│       └── openzeppelin-contracts/

```

---

## Conceito do Contrato `SplitCoordinator`

### Contexto

Imagine que **Alice paga a conta inteira** de um jantar e quer que os amigos devolvam suas partes.
O contrato `SplitCoordinator` gerencia esse processo **de forma descentralizada** — cada amigo aprova (com assinatura e allowance) o valor devido, e o contrato transfere automaticamente os tokens para Alice assim que tudo estiver pronto.

---

### Princípios

| Característica             | Descrição                                                                                                       |
| -------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Sem Custódia**           | Nenhum fundo é depositado no contrato. Ele apenas executa `transferFrom(participant → payer)` usando allowance. |
| **Segurança via EIP-712**  | Aprovação de cobrança é assinada off-chain, validada on-chain com `ecrecover`.                                  |
| **Transparência**          | Estrutura do split (participantes, valores, metaHash, deadlines) é gravada on-chain.                            |
| **Proteção contra replay** | Cada participante é marcado como “approved” e um `salt` único evita reutilização de assinaturas.                |
| **Expiração controlada**   | Cada split e cada assinatura têm deadlines opcionais.                                                           |

---

## Estrutura do Contrato

### `Split`

Representa uma cobrança entre participantes.

| Campo         | Tipo    | Descrição                                   |
| ------------- | ------- | ------------------------------------------- |
| `payer`       | address | Quem pagou a conta (receberá os tokens)     |
| `token`       | address | Token ERC-20 utilizado                      |
| `totalAmount` | uint256 | Soma de todas as partes                     |
| `deadline`    | uint64  | Data limite para liquidação                 |
| `metaHash`    | bytes32 | Hash de metadados off-chain (ex: JSON/IPFS) |
| `settled`     | bool    | Marcador de liquidação concluída            |

---

### `Leg`

Lista de “pernas” do split — quem deve quanto.

| Campo         | Tipo    | Descrição                   |
| ------------- | ------- | --------------------------- |
| `participant` | address | Participante que deve pagar |
| `amount`      | uint256 | Valor devido                |

---

## Fluxo de Execução

### 1. **Criação do Split**

```solidity
createSplit(address payer, address token, Leg[] calldata items, uint64 deadline, bytes32 metaHash)
```

* Armazena quem deve o quê.
* Emite `SplitCreated`.
* Nenhum fundo é movido.

### 2. **Aprovação Off-chain**

Cada participante assina off-chain a seguinte estrutura (EIP-712):

```solidity
ApproveSplit(
    address participant,
    uint256 splitId,
    address token,
    address payer,
    uint256 amount,
    uint256 deadline,
    bytes32 salt
)
```

→ A assinatura é enviada ao backend via API.

### 3. **Liquidação**

```solidity
settleSplit(splitId, participants[], amounts[], deadlines[], salts[], v[], r[], s[])
```

* Verifica:

  * Assinaturas EIP-712 válidas.
  * `amount` = valor definido no split.
  * `allowance` suficiente (`approve(contract, amount)`).
* Executa `transferFrom(participant → payer)` para cada participante.
* Marca split como `settled` e emite `SplitSettled`.

---

## Segurança

| Proteção                         | Descrição                                            |
| -------------------------------- | ---------------------------------------------------- |
| `nonReentrant`                   | evita ataques de reentrância em `settleSplit`        |
| `approved[splitId][participant]` | impede reutilização de assinaturas                   |
| Deadlines                        | expirados não são aceitos                            |
| `metaHash`                       | permite auditar/validar dados off-chain              |
| `amount mismatch`                | impede participantes de assinarem valores incorretos |

--- 

## Setup e Deploy

### Build

```bash
forge clean
forge build -vv
```

### Deploy (Scroll Sepolia)

```bash
export RPC_URL="https://sepolia-rpc.scroll.io"
export PRIVATE_KEY="0xSUA_CHAVE_PRIVADA_DEV"

forge create src/SplitCoordinator.sol:SplitCoordinator \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args "Accountant" "1"
```

**Resultado esperado:**

```
Deployed to: 0x1234...ABCD
Transaction hash: 0x...
```

---

## Ferramentas Utilizadas

| Stack                                | Descrição                             |
| ------------------------------------ | ------------------------------------- |
| **Solidity 0.8.24**                  | Linguagem principal do contrato       |
| **Foundry (Forge)**                  | Framework de build, deploy e teste    |
| **OpenZeppelin v5**                  | Utilitários padrão (ReentrancyGuard)  |
| **EIP-712**                          | Assinaturas off-chain padronizadas    |
| **PostgreSQL + Prisma**              | Persistência off-chain                |
| **Node.js / NestJS (próxima etapa)** | Backend/API de interface com contrato |

---

## Próximos Passos

1. **Implementar testes Foundry**:

   * Mock ERC-20 e `approve` + `settleSplit`.
   * Verificação de assinatura EIP-712.
2. **API NestJS**:

   * `/splits/create`
   * `/splits/:id/approve`
   * `/splits/:id/settle`
3. **WebApp**:

   * Conectar carteira → assinar EIP-712 → enviar ao backend.
   * Exibir splits e status de liquidação.
4. **Monitoramento on-chain**:

   * Escutar evento `SplitSettled` para sincronizar o estado do banco.

---

## Referências Técnicas

* [EIP-712: Typed Structured Data Hashing and Signing](https://eips.ethereum.org/EIPS/eip-712)
* [OpenZeppelin Contracts v5](https://docs.openzeppelin.com/contracts/5.x/)
* [Foundry Book](https://book.getfoundry.sh/)
* [Prisma Docs](https://www.prisma.io/docs)
* [Scroll Testnet RPC](https://scroll.io/)

---

## Conclusão

Esta primeira etapa consolida toda a **infraestrutura base** do *Accountant*:

*  **Contrato auditável e sem custódia** para rateios.
*  **Banco relacional sincronizado** com a blockchain.
*  **Design modular** para conectar API e WebApp nas próximas fases.

> O resultado é um sistema que une a segurança da blockchain com a simplicidade de um app financeiro compartilhado — ideal para o novo mundo Web3.
