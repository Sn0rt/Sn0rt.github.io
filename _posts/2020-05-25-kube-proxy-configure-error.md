---
author: sn0rt
comments: true
date: 2020-05-25
layout: post
title:  kube-proxy 配置不当导致 service 异常
tag: k8s
---

之前调研 nlb 后端获取真实 ip 的特性，发现当 kube-proxy 报错如下的时候就会发生生成的 iptables 规则不符合预期，即丢弃当前 service node port 的流量。

```bash
-A KUBE-XLB-HCMTY43AHEJZZDHI -m comment --comment "2048-game/service-2048: has no local endpoints" -j KUBE-MARK-DROP
```

实际情况是当前节点上运行着 pod

```bash
$ kubectl --kubeconfig kubeconfig -n 2048-game get pod -o wide

NAME                               READY   STATUS    RESTARTS   AGE    IP               NODE                             NOMINATED NODE
2048-deployment-7bddb7dc45-c2dk6   1/1     Running   0          109m   10.188.166.183   ip-10-188-166-140.ec2.internal   <none>
2048-deployment-7bddb7dc45-nc88f   1/1     Running   0          109m   10.188.166.232   ip-10-188-166-140.ec2.internal   <none>
```

而 kubelet 的健康检查却说没有

```json
# curl http://10.188.166.140:32198
{
	"service": {
		"namespace": "2048-game",
		"name": "service-2048"
	},
	"localEndpoints": 0
}
```



# 错误信息收集

检查 kube-proxy 日志发现是 kube-proxy 解析 ip 地址有报错信息

```log
W0525 07:13:03.916890       1 server.go:604] Failed to retrieve node info: nodes "ip-10-188-166-140" not found
I0525 07:13:03.916921       1 server_others.go:148] Using iptables Proxier.
W0525 07:13:03.917047       1 proxier.go:312] invalid nodeIP, initializing kube-proxy with 127.0.0.1 as nodeIP
```

在kube-proxy的逻辑中，这个 ip 地址需要和 endpoint 对象中的 nodeName 做里面的地址匹配

```yaml
....
subsets:
- addresses:
  - ip: 10.188.166.183
    nodeName: ip-10-188-166-140.ec2.internal
    targetRef:
      kind: Pod
      name: 2048-deployment-7bddb7dc45-c2dk6
      namespace: 2048-game
      resourceVersion: "1695104"
      uid: e52b247a-9e51-11ea-b101-02d6ecb85825
  - ip: 10.188.166.232
    nodeName: ip-10-188-166-140.ec2.internal
   ...
```

看下 kube-proxy 的启动关键参数

```
...
I0525 07:13:03.848460       1 flags.go:33] FLAG: --bind-address="0.0.0.0"
...
I0525 07:13:03.848697       1 flags.go:33] FLAG: --hostname-override="ip-10-188-166-140.ec2.internal"
...
```



# 代码逻辑分析

```go
func NewProxier(ipt utiliptables.Interface,
	sysctl utilsysctl.Interface,
	exec utilexec.Interface,
	syncPeriod time.Duration,
	minSyncPeriod time.Duration,
	masqueradeAll bool,
	masqueradeBit int,
	clusterCIDR string,
	hostname string,
	nodeIP net.IP,
	recorder record.EventRecorder,
	healthzServer healthcheck.HealthzUpdater,
	nodePortAddresses []string,
) (*Proxier, error) {
...
	if nodeIP == nil {
		glog.Warningf("invalid nodeIP, initializing kube-proxy with 127.0.0.1 as nodeIP") // 错误信息
		nodeIP = net.ParseIP("127.0.0.1")
	}
```



```go
	nodeIP := net.ParseIP(config.BindAddress) // 这里通过日志看到的输入 0.0.0.0
	if nodeIP.IsUnspecified() { // 这里逻辑应该是命中了，为 true
		nodeIP = getNodeIP(client, hostname)
	}
	if proxyMode == proxyModeIPTables {
		glog.V(0).Info("Using iptables Proxier.")
		if config.IPTables.MasqueradeBit == nil {
			// MasqueradeBit must be specified or defaulted.
			return nil, fmt.Errorf("unable to read IPTables MasqueradeBit from config")
		}

		// TODO this has side effects that should only happen when Run() is invoked.
		proxierIPTables, err := iptables.NewProxier(
```

```go
func getNodeIP(client clientset.Interface, hostname string) net.IP {
	var nodeIP net.IP
	node, err := client.CoreV1().Nodes().Get(hostname, metav1.GetOptions{})
	if err != nil {
		glog.Warningf("Failed to retrieve node info: %v", err) // 这个错误信息也命中，值为 ip-10-188-166-140
		return nil
	}
	nodeIP, err = utilnode.GetNodeHostIP(node)
	if err != nil {
		glog.Warningf("Failed to retrieve node IP: %v", err)
		return nil
	}
	return nodeIP
}
```

这个错误信息就很奇怪，明明前面已经启动了 `--hostname-override="ip-10-188-166-140.ec2.internal"`，为啥还是去获取的主机名称是`ip-10-188-166-140`。

```go
	// Create event recorderc
	hostname, err := utilnode.GetHostname(config.HostnameOverride)
	if err != nil {
		return nil, err
	}
```

看到了变量产生的地方，这个函数`utilnode.GetHostname()`经过单元测试`utilnode.GetHostname(ip-10-188-166-140.ec2.internal)`返回值是`ip-10-188-166-140.ec2.internal`，也是符合预期的。

那就顺藤排查`config.HostnameOverride`变量，发现是如下的命令行参数渲染上来的

```go
	fs.StringVar(&o.config.HostnameOverride, "hostname-override", o.config.HostnameOverride, "If non-empty, will use this string as identification instead of the actual hostname.")
```

有点迷，不能跳着看。

继续看`config.HostnameOverride`这个变量的结构体`config`生成。

```go
func newProxyServer(
	config *proxyconfigapi.KubeProxyConfiguration,
	cleanupAndExit bool,
	cleanupIPVS bool,
	scheme *runtime.Scheme,
	master string) (*ProxyServer, error) {

	if config == nil {
		return nil, errors.New("config is required")
	}
... 移除不相关代码
	// Create event recorderc
	hostname, err := utilnode.GetHostname(config.HostnameOverride)
	if err != nil {
		return nil, err
	}
```

走读如上代码发现是发现`config`对象其实是参数传入的，并且没有特别的修改。

```go
// NewProxyServer returns a new ProxyServer.
func NewProxyServer(o *Options) (*ProxyServer, error) {
	return newProxyServer(o.config, o.CleanupAndExit, o.CleanupIPVS, o.scheme, o.master)
}
```

调用 `NewProxyServer()`函数的是`Run()`中被调用，走读了一下没有发现异常。继续看一下`Run()`函数被调用的地方

```go
func (o *Options) Run() error {
	if len(o.WriteConfigTo) > 0 {
		return o.writeConfigFile()
	}

	proxyServer, err := NewProxyServer(o)
...
}
```

`Run()` 是`NewOptions()`返回对象的方法，

```go
// NewProxyCommand creates a *cobra.Command object with default parameters
func NewProxyCommand() *cobra.Command {
	opts := NewOptions()

	cmd := &cobra.Command{
		...
		Run: func(cmd *cobra.Command, args []string) {
			verflag.PrintAndExitIfRequested()
			utilflag.PrintFlags(cmd.Flags())

			if err := initForOS(opts.WindowsService); err != nil {
				glog.Fatalf("failed OS init: %v", err)
			}

			if err := opts.Complete(); err != nil {
				glog.Fatalf("failed complete: %v", err)
			}
			if err := opts.Validate(args); err != nil {
				glog.Fatalf("failed validate: %v", err)
			}
			glog.Fatal(opts.Run())
		},
	}

	var err error
	opts.config, err = opts.ApplyDefaults(opts.config)
	if err != nil {
		glog.Fatalf("unable to create flag defaults: %v", err)
	}

	opts.AddFlags(cmd.Flags())

	cmd.MarkFlagFilename("config", "yaml", "yml", "json")

	return cmd
}
```

看上面代码知道`NewProxyCommand`返回的是`*cobra.Command`对象，这个框架中实际执行的就是`Run`字段的实现。

```go
// Complete completes all the required options.
func (o *Options) Complete() error {
	if len(o.ConfigFile) == 0 && len(o.WriteConfigTo) == 0 {
		glog.Warning("WARNING: all flags other than --config, --write-config-to, and --cleanup are deprecated. Please begin using a config file ASAP.")
		o.applyDeprecatedHealthzPortToConfig()
	}

	// Load the config file here in Complete, so that Validate validates the fully-resolved config.
	if len(o.ConfigFile) > 0 {
		if c, err := o.loadConfigFromFile(o.ConfigFile); err != nil { // 这里覆盖了
			return err
		} else {
			o.config = c
		}
	}

	err := utilfeature.DefaultFeatureGate.SetFromMap(o.config.FeatureGates)
	if err != nil {
		return err
	}

	return nil
}
```

看了上面代码心凉了，也就是说如果我指定了配置文件那么命令行设置的`flag`也就不生效了。



# 验证结论

```
/usr/local/bin/kube-proxy --hostname-override=ip-10-188-166-140.ec2.internal --v=8
...
I0525 10:19:12.711084    1543 flags.go:33] FLAG: --hostname-override="ip-10-188-166-140.ec2.internal"
...
W0525 10:19:12.711412    1543 server.go:194] WARNING: all flags other than --config, --write-config-to, and --cleanup are deprecated. Please begin using a config file ASAP.
I0525 10:19:12.711447    1543 feature_gate.go:206] feature gates: &{map[]}
I0525 10:19:12.713822    1543 iptables.go:611] couldn't get iptables-restore version; assuming it doesn't support --wait
I0525 10:19:12.721048    1543 server.go:412] Neither kubeconfig file nor master URL was specified. Falling back to in-cluster config.
W0525 10:19:12.722352    1543 server_others.go:295] Flag proxy-mode="" unknown, assuming iptables proxy
I0525 10:19:12.723544    1543 round_trippers.go:383] GET https://192.168.0.1:443/api/v1/nodes/ip-10-188-166-140.ec2.internal
```

符合代码分析，凡事指定`config`就以这个配置文件的内容为准，没有就以命令行的`flag`为准。

后面又看了一下`kubelet`的配置参数，发现在 `kubelet`设计中如果`falg`和 配置文件中同时指定，命令行参数设定值具有更高的优先级。

看上去是个上游`bug`，在当前最新版本有没有这样的问题有待确认。