# Changelog

## v1.0.1

- 完成 RouteBar 原生菜单栏应用的订阅、节点、服务、日志和设置管理界面。
- 支持多订阅导入、VLESS Reality 节点解析、去重、测速、启用状态保留和 sing-box/Surge 配置生成。
- 新增环境设置向导，允许新用户配置 sing-box、Surge、LaunchAgent 和日志路径。
- 新增运行期自动更新；自动更新只在 RouteBar 运行时生效，暂停状态会持久化。
- 新增持久化更新记录，保存到 `~/Library/Application Support/RouteBar/update.log`。
- 优化三栏布局：订阅和节点详情不再默认展开，选择具体项目后再显示右侧详情。
