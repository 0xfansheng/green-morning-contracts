# GREEN MORNING ($GM) · V4

本仓库公开 BNB Smart Chain 主网（chain ID **56**）上 GREEN MORNING 的 V4 实现、ERC-1967 代理、实际编译依赖及可复现的编译输入。V4 从区块 **132224334** 启用。代币持仓、授权和交易都使用代理地址。[V4 升级交易](https://bscscan.com/tx/0x8b7062c52d2503c29c6b8f849f7709205be2e11a88d3f09287b29ea7fe2ed526)

| 用途 | 主网地址 |
| --- | --- |
| GM 代币代理 | [0xf8fb136143E40D1DeC963D5234FB7efCE8B01eC7](https://bscscan.com/address/0xf8fb136143E40D1DeC963D5234FB7efCE8B01eC7) |
| V4 实现 | [0x05105935500F39fd17127D9DC73e5157b9eb825f](https://bscscan.com/address/0x05105935500F39fd17127D9DC73e5157b9eb825f) |
| GM/WBNB 交易对（PancakeSwap V2） | [0xEE5F1330424eBD075D3447Efc972d04844B04F26](https://bscscan.com/address/0xEE5F1330424eBD075D3447Efc972d04844B04F26) |
| 营销金库（核验区块） | [0x149d5c8ee077F837d353f637523d9E5710fEbb99](https://bscscan.com/address/0x149d5c8ee077F837d353f637523d9E5710fEbb99) |
| 黑洞地址（GM 及 LP 凭证） | [0x000000000000000000000000000000000000dEaD](https://bscscan.com/address/0x000000000000000000000000000000000000dEaD) |

### 交易税与权限

与指定 GM/WBNB 池交易时，买入和卖出各收 **2%**。税款中 **25%** 的 GM 直接计入黑洞地址余额，**5%** 进入自动加池队列，其余约 **70%** 进入营销队列（整数尾差归入营销）。V4 的黑洞转账保持 GM 的 `totalSupply()` 不变。普通钱包互转免收上述交易税。

新一轮营销兑换须累计达到门槛。后续卖单触发时，合约按批换取原生 BNB 并支付至营销金库。核验区块的起始门槛为 1,000 万 GM，单次硬上限为 5,800 万 GM；实际批量还受池内储备、当前轮次、价格保护及同次 LP 兑换约束。若金库拒绝接收 BNB，合约会保留可领取的余额。自动加池将 GM 与 WBNB 配对，所得 LP 凭证直接铸给黑洞地址。

该代理可升级。管理员可以替换实现、调整营销门槛和收款地址。下方的链上验证固定在区块 **132225851**，可用来重现这次发布所对应的状态。

### 源码和复核

Sourcify 已对两个合约的创建字节码和运行时字节码给出 `exact_match`。[V4 实现核验](https://sourcify.dev/server/v2/contract/56/0x05105935500F39fd17127D9DC73e5157b9eb825f) · [代理核验](https://sourcify.dev/server/v2/contract/56/0xf8fb136143E40D1DeC963D5234FB7efCE8B01eC7) · [BscScan V4 源码](https://bscscan.com/address/0x05105935500F39fd17127D9DC73e5157b9eb825f#code)

- [V4 主合约](contracts/GreenMorningMarketingV4.sol) · [ERC-1967 代理](%40openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol)
- [V4 ABI](abi/GreenMorningMarketingV4.json) · [代理 ABI](abi/ERC1967Proxy.json)
- [V4 Standard JSON 编译输入](compiler-input/implementation.json) · [代理 Standard JSON 编译输入](compiler-input/proxy.json)
- [主网地址、代理构造参数和字节码校验值](deployments/bsc.json) · [文件 SHA-256 清单](SHA256SUMS)

编译器为 `0.8.38+commit.1835d247`，EVM 目标为 `shanghai`，均关闭 `viaIR`。V4 优化器为 1 run，代理优化器为 200 runs。源码中随附本次编译使用的 OpenZeppelin Contracts / Contracts Upgradeable 5.6.1 依赖。

在装有 Node.js 20 或更新版本和 npm 的环境中运行：

```sh
npm ci --ignore-scripts
npm run build
npm run verify
```

`build` 使用所附源码重新编译两个合约，校验 ABI、创建字节码哈希以及运行时代码哈希。V4 的 UUPS 不可变变量 `__self` 按编译器给出的偏移填入部署地址。`verify` 额外只读查询 BSC，逐字节比对链上代码，核验代理实现槽、代理部署交易及 V4 升级回执。

项目合约使用 [MIT 许可证](LICENSE)。随附的 OpenZeppelin 代码保留其 [原版权和 MIT 许可证](licenses/OpenZeppelin-MIT.txt)。
