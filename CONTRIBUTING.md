# Contributing

感谢改进 Display Steward。项目以显示器安全和可解释行为为第一优先级；任何自动化变化都必须证明不会关闭最后一台可用显示器，也不会丢失恢复证据。

## 开发环境

- macOS 13+
- Xcode Command Line Tools
- 不需要第三方依赖或包管理器

首次验证：

```sh
./test-all.sh
./install.sh --smoke-test
```

## 修改原则

- 保持原生 AppKit / Foundation / CoreGraphics / Carbon 实现，不引入辅助应用或运行时依赖。
- Profile 只拥有名称、自动化、轮询和规则；热键、显示器历史及恢复证据保持应用级共享。
- Profile 只能由用户手动激活，不能根据显示器拓扑隐式选择。
- 显示器动作必须绑定最新观察、通过最后活动屏检查，并在提交前持久化必要恢复证据。
- 损坏配置必须保留为证据；禁止静默修复、覆盖或随机回退到其他 Profile。
- Settings 草稿必须绑定一个 Profile 身份；普通导航不能产生硬件副作用。
- 避免顺手重构。每一处修改都应直接服务于当前行为契约。

领域词汇见 `CONTEXT.md`，产品原则见 `SOUL.md`，难以回退的决策见 `docs/adr/`。

## 测试范围

根据改动选择最小相关阶段，并在提交前运行完整套件：

```sh
./test-phase1.sh  # 模型、规则、存储、迁移
./test-phase2.sh  # 清单、动作、协调器、恢复
./test-phase3.sh  # Presentation、草稿、AppKit seams
./test-phase4.sh  # 启动与端到端集成
./test-all.sh
```

测试应保护可观察契约，并能在真实缺陷下失败。优先覆盖：

- 配置损坏、进程中断和代次回退；
- Profile 身份、Active selector 和迁移幂等性；
- 显示器拓扑变化、陈旧计划和部分提交；
- 最后活动屏、恢复证据及运行期 ID 重用；
- 草稿保存、放弃、取消和破坏性确认；
- Profile 选择事实与硬件执行结果的区分。

## 构建与 Bundle 检查

```sh
./build.sh
./install.sh --smoke-test
```

`--smoke-test` 不会安装或启动应用。需要测试真实显示器动作时，必须明确控制场景，确保至少两台活动显示器，并记录操作前后状态；不要把真实硬件动作加入默认测试套件。

## 文档同步

行为或边界改变时同步更新：

- `README.md`：用户可见能力、安装和使用；
- `CONTEXT.md`：领域术语；
- `SOUL.md`：长期产品原则；
- `docs/adr/`：难以回退、存在真实取舍且代码本身无法解释的决策。

不要为容易回退或显而易见的实现创建 ADR。
