// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Reentrancy guard (OpenZeppelin v5 já está no seu repo em lib/)
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/**
 * @title SplitCoordinator (modo allowance, sem depósito)
 * @notice Fluxo:
 *  - createSplit(): registra um split e suas legs (participants/amounts).
 *  - Cada participante assina off-chain (EIP-712) aprovando sua leg.
 *  - settleSplit(): verifica assinaturas, checa allowance e transfere via transferFrom(participant -> payer).
 */
contract SplitCoordinator is ReentrancyGuard {
    // ---------------------- Types ----------------------

    struct Split {
        address payer;         // quem adiantou o pagamento
        address token;         // ERC-20 usado no split
        uint256 totalAmount;   // soma das legs
        uint64  createdAt;     // timestamp
        uint64  deadline;      // expiração do split (0 = sem expiração)
        bytes32 metaHash;      // hash de metadados off-chain (ex: recibo/JSON/IPFS)
        bool    settled;       // já liquidado?
    }

    struct Leg {
        address participant;
        uint256 amount;
    }

    // EIP-712 ApproveSplit struct
    // hash struct: ApproveSplit(address participant,uint256 splitId,address token,address payer,uint256 amount,uint256 deadline,bytes32 salt)
    bytes32 public constant APPROVE_TYPEHASH = keccak256(
        "ApproveSplit(address participant,uint256 splitId,address token,address payer,uint256 amount,uint256 deadline,bytes32 salt)"
    );

    // ---------------------- Storage ----------------------

    bytes32 public DOMAIN_SEPARATOR;
    uint256 public splitsCount;

    mapping(uint256 => Split) public splits;
    mapping(uint256 => Leg[]) public legs; // legs[splitId] -> array de legs

    // splitId => participant => approved?
    mapping(uint256 => mapping(address => bool)) public approved;

    // ---------------------- Events ----------------------

    event SplitCreated(
        uint256 indexed splitId,
        address indexed payer,
        address indexed token,
        uint256 total,
        uint64 deadline,
        bytes32 metaHash
    );

    event SplitApproved(uint256 indexed splitId, address indexed participant, uint256 amount);

    event SplitSettled(uint256 indexed splitId, address indexed payer);

    // ---------------------- Ctor / EIP-712 ----------------------

    constructor(string memory name, string memory version) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                address(this)
            )
        );
    }

    // ---------------------- Core ----------------------

    /**
     * @dev Cria um split com legs definidas. Armazena tudo on-chain para imutabilidade/auditoria.
     */
    function createSplit(
        address payer,
        address token,
        Leg[] calldata items,
        uint64 deadline,
        bytes32 metaHash
    ) external returns (uint256 splitId) {
        require(payer != address(0) && token != address(0), "invalid addr");
        uint256 n = items.length;
        require(n > 0, "no legs");

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            address p = items[i].participant;
            uint256 a = items[i].amount;
            require(p != address(0), "leg addr");
            require(a > 0, "leg amt");
            total += a;
        }

        splitId = ++splitsCount;

        splits[splitId] = Split({
            payer: payer,
            token: token,
            totalAmount: total,
            createdAt: uint64(block.timestamp),
            deadline: deadline,
            metaHash: metaHash,
            settled: false
        });

        for (uint256 i = 0; i < n; i++) {
            legs[splitId].push(Leg(items[i].participant, items[i].amount));
        }

        emit SplitCreated(splitId, payer, token, total, deadline, metaHash);
    }

    /**
     * @dev Verifica assinatura EIP-712 de aprovação de um participante para um split específico.
     */
    function verifyApprovalSig(
        uint256 splitId,
        address participant,
        uint256 amount,
        uint256 deadline,
        bytes32 salt,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view returns (bool) {
        Split memory sp = splits[splitId];
        require(sp.payer != address(0), "split !exists");
        if (deadline != 0) {
            require(block.timestamp <= deadline, "approval expired");
        }

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        APPROVE_TYPEHASH,
                        participant,
                        splitId,
                        sp.token,
                        sp.payer,
                        amount,
                        deadline,
                        salt
                    )
                )
            )
        );

        address signer = ecrecover(digest, v, r, s);
        return signer == participant;
    }

    /**
     * @dev Liquida o split: verifica assinaturas, confere valores esperados, allowance e executa transferFrom().
     * Arrays devem ser paralelos e de mesmo tamanho.
     */
    function settleSplit(
        uint256 splitId,
        address[] calldata participants,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        bytes32[] calldata salts,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external nonReentrant {
        Split storage sp = splits[splitId];
        require(sp.payer != address(0), "split !exists");
        require(!sp.settled, "already settled");
        if (sp.deadline != 0) {
            require(block.timestamp <= sp.deadline, "split expired");
        }

        uint256 n = participants.length;
        require(
            n == amounts.length &&
            n == deadlines.length &&
            n == salts.length &&
            n == v.length &&
            n == r.length &&
            n == s.length,
            "array len mismatch"
        );

        // monta um mapa (em memória) de valor devido por participante com base nas legs registradas
        // isso garante que a assinatura apresentada bate com a obrigação registrada on-chain
        // (protege contra "aprovar menos" do que deveria)
        // Nota: como mappings em memória não existem, vamos fazer lookup por varredura O(N).
        // Para grupos >20 pode afetar gas; aceitável para MVP.
        for (uint256 i = 0; i < n; i++) {
            address part = participants[i];
            uint256 expected = _requiredAmount(splitId, part);
            require(expected > 0, "participant not in split");
            require(amounts[i] == expected, "amount mismatch");
        }

        IERC20 token = IERC20(sp.token);

        // valida assinaturas e allowance antes de transferir
        for (uint256 i = 0; i < n; i++) {
            address part = participants[i];
            require(!approved[splitId][part], "already approved");

            bool ok = verifyApprovalSig(
                splitId,
                part,
                amounts[i],
                deadlines[i],
                salts[i],
                v[i],
                r[i],
                s[i]
            );
            require(ok, "bad sig");

            // checa allowance suficiente para evitar tokens que retornam false silenciosamente
            uint256 allow = token.allowance(part, address(this));
            require(allow >= amounts[i], "insufficient allowance");

            approved[splitId][part] = true;
            emit SplitApproved(splitId, part, amounts[i]);
        }

        // transfers
        for (uint256 i = 0; i < n; i++) {
            // transferFrom(participant -> payer)
            bool success = token.transferFrom(participants[i], sp.payer, amounts[i]);
            require(success, "transferFrom failed");
        }

        sp.settled = true;
        emit SplitSettled(splitId, sp.payer);
    }

    /**
     * @dev Retorna quanto o participante deve neste split (0 se não participa).
     */
    function requiredAmount(uint256 splitId, address participant) external view returns (uint256) {
        return _requiredAmount(splitId, participant);
    }

    // ---------------------- Internals ----------------------

    function _requiredAmount(uint256 splitId, address participant) internal view returns (uint256) {
        Leg[] storage arr = legs[splitId];
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; i++) {
            if (arr[i].participant == participant) {
                return arr[i].amount;
            }
        }
        return 0;
    }
}
