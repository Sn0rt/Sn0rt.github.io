---
author: sn0rt
comments: true
date: 2019-11-25
layout: post
title:  amzon aws cni 踩坑2
tag: k8s
---

目前业务上准备试用 aws vpc cni 方案, 之前遇到了一些 cni 的使用问题发现还有一些细节不了解.

遂去尝试使用它提供的一些特性开关, 在试用 `AWS_VPC_K8S_CNI_EXTERNALSNAT` 开关, 重建了 aws node ds, 发现 ec2 节点的 网卡被 deattach 了, 继而导致了使用了绑定在这个网卡上的浮动ip的 pod 失联了.

结论: 是 ipamd deattach 了 eni, 是 ipamd delete 了 eni. 


ipamd 这也的逻辑很奇怪, 看代码没有发现明显逻辑问题.

## 代码分析

下面就是 `ipamd` 的起手代码, 无关逻辑直接删除了方便梳理核心.

```go
func _main() int {
...
	discoverController := k8sapi.NewController(kubeClient)
	go discoverController.DiscoverK8SPods()

	eniConfigController := eniconfig.NewENIConfigController()
...
	ipamContext, err := ipamd.New(discoverController, eniConfigController)

	if err != nil {
		log.Errorf("Initialization failure: %v", err)
		return 1
	}
	...
}
```

上述代码和重逻辑, 核心在 `ipamd.New` 的实现中, 下面就看一下这个 `function` 的实现

```go
// New retrieves IP address usage information from Instance MetaData service and Kubelet
// then initializes IP address pool data store
func New(k8sapiClient k8sapi.K8SAPIs, eniConfig *eniconfig.ENIConfigController) (*IPAMContext, error) {
...
	c.warmENITarget = getWarmENITarget()
	c.warmIPTarget = getWarmIPTarget()

	err = c.nodeInit()
...
```

上述代码就是函数核心,看一下官方的的设计提议里面`L-IPAM can immediately take one available secondary IP address from its warm pool and assign it to Pod.`,  那两行代码就是准备去满足这个设计需求的.

其实后面 `nodeInit` 才是这一串代码中的关键点.

```go
//TODO need to break this function down(comments from CR)
func (c *IPAMContext) nodeInit() error {
...
	c.maxENI, err = c.getMaxENI()
	if err != nil {
		log.Error("Failed to get ENI limit")
		return err
	}
	enisMax.Set(float64(c.maxENI))

	c.maxIPsPerENI, err = c.awsClient.GetENIipLimit()
	if err != nil {
		log.Error("Failed to get IPs per ENI limit")
		return err
	}
	ipMax.Set(float64(c.maxIPsPerENI * c.maxENI)) // 因为 ec2 不同机型可以添加 eni 以及每个 eni 上附加的 ip 数量不一致.

	c.useCustomNetworking = UseCustomNetworkCfg()
	c.primaryIP = make(map[string]string)
	c.reconcileCooldownCache.cache = make(map[string]time.Time)

	enis, err := c.awsClient.GetAttachedENIs()
	if err != nil {
		log.Error("Failed to retrieve ENI info")
		return errors.New("ipamd init: failed to retrieve attached ENIs info")
	}

	_, vpcCIDR, err := net.ParseCIDR(c.awsClient.GetVPCIPv4CIDR())
	if err != nil {
		log.Error("Failed to parse VPC IPv4 CIDR", err.Error())
		return errors.Wrap(err, "ipamd init: failed to retrieve VPC CIDR")
	}

	primaryIP := net.ParseIP(c.awsClient.GetLocalIPv4())
	err = c.networkClient.SetupHostNetwork(vpcCIDR, c.awsClient.GetVPCIPv4CIDRs(), c.awsClient.GetPrimaryENImac(), &primaryIP)
	if err != nil {
		log.Error("Failed to set up host network", err)
		return errors.Wrap(err, "ipamd init: failed to set up host network")
	}

	c.dataStore = datastore.NewDataStore() // 这里就是创建那个本地 ip 池的数据结构了
	for _, eni := range enis {
		log.Debugf("Discovered ENI %s, trying to set it up", eni.ENIID)
		// Retry ENI sync
		retry := 0
		for {
			retry++
			err = c.setupENI(eni.ENIID, eni)
			// 这个函数只要干三件事情 
			// 1 把 eni 添加到 datastore中. 
			// 2 把 设置Linux eni 相关, 
			// 3 将 eni 的浮动 ip 放置到 datastore 中
			// 虽然都是与本次问题没有关系的.
			if retry > maxRetryCheckENI {
				log.Errorf("Unable to discover attached IPs for ENI from metadata service")
				ipamdErrInc("waitENIAttachedMaxRetryExceeded")
				break
			}
...
			break
		}
	}

	usedIPs, err := c.getLocalPodsWithRetry()
	log.Debugf("getLocalPodsWithRetry() found %d used IPs.", len(usedIPs))
	// 上面 function 重建本地 pod 信息, 包括 name/namespace/ip/containerid
	
	if err != nil {
		log.Warnf("During ipamd init, failed to get Pod information from kubelet %v", err)
		ipamdErrInc("nodeInitK8SGetLocalPodIPsFailed")
		// This can happens when L-IPAMD starts before kubelet.
		// TODO  need to add node health stats here
		return errors.Wrap(err, "failed to get running pods!")
	}

	rules, err := c.networkClient.GetRuleList()
	if err != nil {
		log.Errorf("During ipamd init: failed to retrieve IP rule list %v", err)
		return nil
	}

	for _, ip := range usedIPs {
		if ip.Container == "" {
			log.Infof("Skipping Pod %s, Namespace %s, due to no matching container", ip.Name, ip.Namespace)
			continue
		}
		if ip.IP == "" {
			log.Infof("Skipping Pod %s, Namespace %s, due to no IP", ip.Name, ip.Namespace)
			continue
		}
		log.Infof("Recovered AddNetwork for Pod %s, Namespace %s, Container %s", ip.Name, ip.Namespace, ip.Container)
		_, _, err = c.dataStore.AssignPodIPv4Address(ip)
		if err != nil {
			ipamdErrInc("nodeInitAssignPodIPv4AddressFailed")
			log.Warnf("During ipamd init, failed to use pod IP %s returned from Kubelet %v", ip.IP, err)
			// TODO continue, but need to add node health stats here
			// TODO need to feed this to controller on the health of pod and node
			// This is a bug among kubelet/cni-plugin/l-ipamd/ec2-metadata that this particular pod is using an non existent ip address.
			// Here we choose to continue instead of returning error and EXIT out L-IPAMD(exit L-IPAMD will make whole node out)
			// The plan(TODO) is to feed this info back to controller and let controller cleanup this pod from this node.
		}

		// Update ip rules in case there is a change in VPC CIDRs, AWS_VPC_K8S_CNI_EXTERNALSNAT setting
		srcIPNet := net.IPNet{IP: net.ParseIP(ip.IP), Mask: net.IPv4Mask(255, 255, 255, 255)}
		vpcCIDRs := c.awsClient.GetVPCIPv4CIDRs()

		var pbVPCcidrs []string
		for _, cidr := range vpcCIDRs {
			pbVPCcidrs = append(pbVPCcidrs, *cidr)
		}

		err = c.networkClient.UpdateRuleListBySrc(rules, srcIPNet, pbVPCcidrs, !c.networkClient.UseExternalSNAT())
		if err != nil {
			log.Errorf("UpdateRuleListBySrc in nodeInit() failed for IP %s: %v", ip.IP, err)
		}
	}
	return nil
}
```

稍微小结一下, 上面是初始化流程, 每一次启动的时候 ipamd 会在本地建一个地址池, 并通过本地一个 `dataStore`来标记地址池的分配状态. 

具体的下方规则在我们这个问题里面并不关心, 是因为我遇到的不是`iptables`的转发问题.

看一下每次重启重新标记分配出去的 `ip` 的逻辑, 其实核心逻辑就是 `assignPodIPv4AddressUnsafe` 中在内存中重建分配数据.

```go
// AssignPodIPv4Address assigns an IPv4 address to pod
// It returns the assigned IPv4 address, device number, error
func (ds *DataStore) AssignPodIPv4Address(k8sPod *k8sapi.K8SPodInfo) (string, int, error) {
	ds.lock.Lock()
	defer ds.lock.Unlock()

	log.Debugf("AssignIPv4Address: IP address pool stats: total: %d, assigned %d", ds.total, ds.assigned)
	podKey := PodKey{
		name:      k8sPod.Name,
		namespace: k8sPod.Namespace,
		container: k8sPod.Container,
	}
	ipAddr, ok := ds.podsIP[podKey]
	if ok {
		if ipAddr.IP == k8sPod.IP && k8sPod.IP != "" {
			// The caller invoke multiple times to assign(PodName/NameSpace --> same IPAddress). It is not a error, but not very efficient.
			log.Infof("AssignPodIPv4Address: duplicate pod assign for IP %s, name %s, namespace %s, container %s",
				k8sPod.IP, k8sPod.Name, k8sPod.Namespace, k8sPod.Container)
			return ipAddr.IP, ipAddr.DeviceNumber, nil
		}
		// TODO Handle this bug assert? May need to add a counter here, if counter is too high, need to mark node as unhealthy...
		//      This is a bug that the caller invokes multiple times to assign(PodName/NameSpace -> a different IP address).
		log.Errorf("AssignPodIPv4Address: current IP %s is changed to IP %s for pod(name %s, namespace %s, container %s)",
			ipAddr, k8sPod.IP, k8sPod.Name, k8sPod.Namespace, k8sPod.Container)
		return "", 0, errors.New("AssignPodIPv4Address: invalid pod with multiple IP addresses")
	}
	return ds.assignPodIPv4AddressUnsafe(k8sPod)
}
```

## 日志分析

第一段是无关代码,基本的一些版本信息
```
2019-11-26T02:28:11.342Z [INFO]	Starting L-IPAMD v1.5.3  ...
2019-11-26T02:28:11.380Z [INFO]	Testing communication with server
2019-11-26T02:28:11.380Z [INFO]	Running with Kubernetes cluster version: v1.12. git version: v1.12.4+0422-clusterip-bugfix. git tree state: archive. commit: f49fa022dbe63faafd0da106ef7e05a29721d3f1. platform: linux/amd64
2019-11-26T02:28:11.380Z [INFO]	Communication with server successful
```

main 函数开始了, 通过 `ec2` 的 `metadata` 接口通过 discover 函数的实现来收集 ipamd 启动需要的信息.

```
2019-11-26T02:28:11.380Z [INFO]	Starting Pod controller
2019-11-26T02:28:11.380Z [INFO]	Waiting for controller cache sync
2019-11-26T02:28:11.382Z [DEBUG]	Discovered region: us-east-1
2019-11-26T02:28:11.382Z [DEBUG]	Found availability zone: us-east-1a
2019-11-26T02:28:11.383Z [DEBUG]	Discovered the instance primary ip address: 10.0.10.66
2019-11-26T02:28:11.383Z [DEBUG]	Found instance-id: i-0ba03a7c305eb480c
2019-11-26T02:28:11.384Z [DEBUG]	Found instance-type: c5.xlarge
2019-11-26T02:28:11.384Z [DEBUG]	Found primary interface's MAC address: 02:43:a8:0e:05:2f
2019-11-26T02:28:11.384Z [DEBUG]	Discovered 2 interfaces.
2019-11-26T02:28:11.385Z [DEBUG]	Found device-number: 0
2019-11-26T02:28:11.385Z [DEBUG]	Found account ID: 179516646050
2019-11-26T02:28:11.386Z [DEBUG]	Found eni: eni-0debffa6dcf067b1b
2019-11-26T02:28:11.386Z [DEBUG]	Found ENI eni-0debffa6dcf067b1b is a primary ENI
2019-11-26T02:28:11.392Z [DEBUG]	Found security-group id: sg-0ade1b7b97edfbc0b
2019-11-26T02:28:11.392Z [DEBUG]	Found security-group id: sg-05c56cb6937b7cd9e
2019-11-26T02:28:11.393Z [DEBUG]	Found subnet-id: subnet-048c7f0d1e821113d
2019-11-26T02:28:11.393Z [DEBUG]	Found vpc-ipv4-cidr-block: 10.0.0.0/16
2019-11-26T02:28:11.394Z [DEBUG]	Found VPC CIDR: 10.0.0.0/16
```

下面就是准备 node init 了, 准备本地路由表, 转发规则, 建立本地址池.

其中建立地址池的过程概述就是获取弹性网卡, 从弹性网卡上获取浮动ip,将浮动ip放到进程缓存中, 然后调用 k8s 接口 和 docker 接口重建本地 ip 分配关系.

```
2019-11-26T02:28:11.394Z [DEBUG]	Start node init
2019-11-26T02:28:11.394Z [DEBUG]	Total number of interfaces found: 2
2019-11-26T02:28:11.394Z [DEBUG]	Found ENI mac address : 02:43:a8:0e:05:2f
2019-11-26T02:28:11.395Z [DEBUG]	Using device number 0 for primary eni: eni-0debffa6dcf067b1b
2019-11-26T02:28:11.395Z [DEBUG]	Found ENI: eni-0debffa6dcf067b1b, MAC 02:43:a8:0e:05:2f, device 0
2019-11-26T02:28:11.396Z [DEBUG]	Found CIDR 10.0.10.0/24 for ENI 02:43:a8:0e:05:2f
2019-11-26T02:28:11.397Z [DEBUG]	Found IP addresses [10.0.10.66 10.0.10.192 10.0.10.130 10.0.10.227 10.0.10.166 10.0.10.72 10.0.10.40 10.0.10.136 10.0.10.113 10.0.10.115 10.0.10.53 10.0.10.22 10.0.10.25 10.0.10.26 10.0.10.95] on ENI 02:43:a8:0e:05:2f
2019-11-26T02:28:11.397Z [DEBUG]	Found ENI mac address : 02:ef:be:01:7c:ad
2019-11-26T02:28:11.398Z [DEBUG]	Found ENI: eni-08bafec9495ebc6df, MAC 02:ef:be:01:7c:ad, device 2
2019-11-26T02:28:11.398Z [DEBUG]	Found CIDR 10.0.10.0/24 for ENI 02:ef:be:01:7c:ad
2019-11-26T02:28:11.399Z [DEBUG]	Found IP addresses [10.0.10.43 10.0.10.97 10.0.10.34 10.0.10.35 10.0.10.132 10.0.10.70 10.0.10.231 10.0.10.112 10.0.10.208 10.0.10.177 10.0.10.114 10.0.10.214 10.0.10.87 10.0.10.119 10.0.10.185] on ENI 02:ef:be:01:7c:ad
2019-11-26T02:28:11.399Z [INFO]	Setting up host network...
2019-11-26T02:28:11.399Z [DEBUG]	Trying to find primary interface that has mac : 02:43:a8:0e:05:2f
2019-11-26T02:28:11.399Z [DEBUG]	Discovered interface: lo, mac:
2019-11-26T02:28:11.399Z [DEBUG]	Discovered interface: eth0, mac: 02:43:a8:0e:05:2f
2019-11-26T02:28:11.399Z [INFO]	Discovered primary interface: eth0
2019-11-26T02:28:11.399Z [DEBUG]	Setting RPF for primary interface: /proc/sys/net/ipv4/conf/eth0/rp_filter
2019-11-26T02:28:11.400Z [DEBUG]	Setup Host Network: iptables -N AWS-SNAT-CHAIN-0 -t nat
2019-11-26T02:28:11.401Z [DEBUG]	Setup Host Network: iptables -N AWS-SNAT-CHAIN-1 -t nat
2019-11-26T02:28:11.402Z [DEBUG]	Setup Host Network: iptables -A POSTROUTING -m comment --comment "AWS SNAT CHAIN" -j AWS-SNAT-CHAIN-0
2019-11-26T02:28:11.402Z [DEBUG]	Setup Host Network: iptables -A AWS-SNAT-CHAIN-0 ! -d 10.0.0.0/16 -t nat -j AWS-SNAT-CHAIN-1
2019-11-26T02:28:11.402Z [DEBUG]	iptableRules: [nat/POSTROUTING rule first SNAT rules for non-VPC outbound traffic nat/AWS-SNAT-CHAIN-0 rule [0] AWS-SNAT-CHAIN nat/AWS-SNAT-CHAIN-1 rule last SNAT rule for non-VPC outbound traffic]
2019-11-26T02:28:11.402Z [DEBUG]	execute iptable rule : first SNAT rules for non-VPC outbound traffic
2019-11-26T02:28:11.403Z [DEBUG]	execute iptable rule : [0] AWS-SNAT-CHAIN
2019-11-26T02:28:11.403Z [DEBUG]	execute iptable rule : last SNAT rule for non-VPC outbound traffic
2019-11-26T02:28:11.404Z [DEBUG]	execute iptable rule : connmark for primary ENI
2019-11-26T02:28:11.405Z [DEBUG]	execute iptable rule : connmark restore for primary ENI
2019-11-26T02:28:11.406Z [DEBUG]	execute iptable rule : rule for primary address 10.0.10.66
2019-11-26T02:28:11.407Z [DEBUG]	Discovered ENI eni-0debffa6dcf067b1b, trying to set it up
```

下面就是重建地址池分配的细节

```
2019-11-26T02:28:11.481Z [INFO]	Synced successfully with APIServer
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-telemetry-6dbd664c76-2m4x4 on my node, namespace = istio-system, IP = 10.0.10.136
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod cni-metrics-helper-7774cb895c-cfhlh on my node, namespace = kube-system, IP = 10.0.10.113
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-galley-59fd9c6c8-vxmsn on my node, namespace = istio-system, IP = 10.0.10.22
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod kiali-7b5b867f8-hn9pg on my node, namespace = istio-system, IP = 10.0.10.130
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-citadel-864989dd69-lx72c on my node, namespace = istio-system, IP = 10.0.10.227
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-egressgateway-6bc7c7874f-dvkpx on my node, namespace = istio-system, IP = 10.0.10.115
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod kiali-7b5b867f8-gr6bf on my node, namespace = istio-system, IP = 10.0.10.136
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod grafana-7869478fc5-vh4fs on my node, namespace = istio-system, IP = 10.0.10.40
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-ingressgateway-756fd55f-mlf9w on my node, namespace = istio-system, IP = 10.0.10.59
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-tracing-79db5954f-8bkw7 on my node, namespace = istio-system, IP = 10.0.10.166
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-policy-7984978f85-s4pzk on my node, namespace = istio-system, IP = 10.0.10.53
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-sidecar-injector-7dc597dfc7-n8s2k on my node, namespace = istio-system, IP = 10.0.10.95
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod metrics-server-c654cf865-rt9rp on my node, namespace = kube-system, IP = 10.0.10.95
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod istio-pilot-5cdcc74bf9-h8ghs on my node, namespace = istio-system, IP = 10.0.10.165
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod prometheus-5b48f5d49-nvtc8 on my node, namespace = istio-system, IP = 10.0.10.161
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod kiali-7b5b867f8-bhgh8 on my node, namespace = istio-system, IP = 10.0.10.227
2019-11-26T02:28:11.481Z [INFO]	Add/Update for CNI pod aws-node-knkw9
2019-11-26T02:28:11.481Z [INFO]	Add/Update for CNI pod aws-node-67hv5
2019-11-26T02:28:11.481Z [INFO]	Add/Update for Pod kiali-7b5b867f8-4bcl6 on my node, namespace = istio-system, IP = 10.0.10.40
2019-11-26T02:28:11.564Z [DEBUG]	DataStore Add an ENI eni-0debffa6dcf067b1b
2019-11-26T02:28:11.564Z [DEBUG]	Adding ENI(eni-0debffa6dcf067b1b)'s IPv4 address 10.0.10.192 to datastore
2019-11-26T02:28:11.564Z [DEBUG]	IP Address Pool stats: total: 0, assigned: 0
2019-11-26T02:28:11.564Z [INFO]	Added ENI(eni-0debffa6dcf067b1b)'s IP 10.0.10.192 to datastore
2019-11-26T02:28:11.564Z [DEBUG]	Adding ENI(eni-0debffa6dcf067b1b)'s IPv4 address 10.0.10.130 to datastore
...
2019-11-26T02:28:11.565Z [DEBUG]	Adding ENI(eni-0debffa6dcf067b1b)'s IPv4 address 10.0.10.95 to datastore
2019-11-26T02:28:11.565Z [DEBUG]	IP Address Pool stats: total: 13, assigned: 0
2019-11-26T02:28:11.565Z [INFO]	Added ENI(eni-0debffa6dcf067b1b)'s IP 10.0.10.95 to datastore
2019-11-26T02:28:11.565Z [INFO]	ENI eni-0debffa6dcf067b1b set up.
2019-11-26T02:28:11.565Z [DEBUG]	Discovered ENI eni-08bafec9495ebc6df, trying to set it up
2019-11-26T02:28:11.666Z [DEBUG]	DataStore Add an ENI eni-08bafec9495ebc6df
2019-11-26T02:28:11.666Z [INFO]	Setting up network for an ENI with IP address 10.0.10.43, MAC address 02:ef:be:01:7c:ad, CIDR 10.0.10.0/24 and route table 2
2019-11-26T02:28:11.666Z [DEBUG]	Found the Link that uses mac address 02:ef:be:01:7c:ad and its index is 77 (attempt 1/5)
2019-11-26T02:28:11.666Z [DEBUG]	Setting up ENI's primary IP 10.0.10.43
2019-11-26T02:28:11.666Z [DEBUG]	Deleting existing IP address 10.0.10.43/24 eth1
2019-11-26T02:28:11.667Z [DEBUG]	Adding IP address 10.0.10.43/24
2019-11-26T02:28:11.667Z [DEBUG]	Setting up ENI's default gateway 10.0.10.1
2019-11-26T02:28:11.667Z [DEBUG]	Successfully added route route 10.0.10.1/0 via 10.0.10.1 table 2
2019-11-26T02:28:11.667Z [DEBUG]	Successfully added route route 0.0.0.0/0 via 10.0.10.1 table 2
...
2019-11-26T02:28:11.668Z [INFO]	K8SGetLocalPodIPs discovered local Pods: grafana-7869478fc5-vh4fs istio-system 10.0.10.40 325fa5b9-0f5f-11ea-baca-0262684723a1
```

下面的日志就是本次问题的核心了, 我还一直很奇怪为什么日志总是说 `IP pool stats: total = 28, used = 0, c.maxIPsPerENI = 14` 这样的信息, 因为在我看来这个节点上使用 aws cni pod 的数量更本不是 0 个.

```
2019-11-26T02:28:11.668Z [INFO]	Not able to get local containers yet (attempt 1/5): Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
2019-11-26T02:28:11.702Z [INFO]	Add/Update for Pod cni-metrics-helper-7774cb895c-cfhlh on my node, namespace = kube-system, IP = 10.0.10.113
...
2019-11-26T02:28:14.668Z [INFO]	Not able to get local containers yet (attempt 2/5): Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
2019-11-26T02:28:14.699Z [INFO]	Add/Update for CNI pod aws-node-67hv5
2019-11-26T02:28:15.501Z [INFO]	Add/Update for Pod istio-tracing-79db5954f-8bkw7 on my node, namespace = istio-system, IP = 10.0.10.166
2019-11-26T02:28:15.899Z [INFO]	Add/Update for Pod grafana-7869478fc5-vh4fs on my node, namespace = istio-system, IP = 10.0.10.40
2019-11-26T02:28:16.298Z [INFO]	Add/Update for Pod istio-sidecar-injector-7dc597dfc7-n8s2k on my node, namespace = istio-system, IP = 10.0.10.95
2019-11-26T02:28:16.698Z [INFO]	Add/Update for Pod prometheus-5b48f5d49-nvtc8 on my node, namespace = istio-system, IP = 10.0.10.161
2019-11-26T02:28:17.669Z [INFO]	Not able to get local containers yet (attempt 3/5): Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
2019-11-26T02:28:20.669Z [INFO]	Not able to get local containers yet (attempt 4/5): Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
2019-11-26T02:28:23.669Z [INFO]	Not able to get local containers yet (attempt 5/5): Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
2019-11-26T02:28:26.669Z [DEBUG]	getLocalPodsWithRetry() found 17 used IPs.
2019-11-26T02:28:26.669Z [INFO]	Skipping Pod istio-ingressgateway-756fd55f-mlf9w, Namespace istio-system, due to no matching container
2019-11-26T02:28:26.669Z [INFO]	Skipping Pod istio-tracing-79db5954f-8bkw7, Namespace istio-system, due to no matching container
2019-11-26T02:28:26.669Z [INFO]	Skipping Pod prometheus-5b48f5d49-nvtc8, Namespace istio-system, due to no matching container
2019-11-26T02:28:26.669Z [INFO]	Skipping Pod istio-telemetry-6dbd664c76-2m4x4, Namespace istio-system, due to no matching container
2019-11-26T02:28:26.669Z [INFO]	Skipping Pod kiali-7b5b867f8-hn9pg, Namespace istio-system, due to no matching container
...
// 这一段都是 INFO 级别 skip 信息.
2019-11-26T02:28:26.669Z [INFO]	Skipping Pod grafana-7869478fc5-vh4fs, Namespace istio-system, due to no matching container
```

```go
func (c *IPAMContext) getLocalPodsWithRetry() ([]*k8sapi.K8SPodInfo, error) {
	var pods []*k8sapi.K8SPodInfo
	var err error
	for retry := 1; retry <= maxK8SRetries; retry++ {
		pods, err = c.k8sClient.K8SGetLocalPodIPs()
...
	var containers map[string]*docker.ContainerInfo
	for retry := 1; retry <= maxK8SRetries; retry++ {
		containers, err = c.dockerClient.GetRunningContainers() 
		// 日志就是在这个函数里面打出来的, 这个时候 container id 就是空的
	// TODO consider using map
	for _, pod := range pods {
		// needs to find the container ID
		for _, container := range containers { // 这里发现是空的
			if container.K8SUID == pod.UID {
				log.Debugf("Found pod(%v)'s container ID: %v ", container.Name, container.ID)
				pod.Container = container.ID
				break
			}
		}
	}
	return pods, nil
	// 这里返回 ipamd 记录的 pod 信息里面就没有 container id
}
```

返回 `getLocalPodsWithRetry` 的调用方 `nodeinit` 函数, 看一下相关逻辑, 当 container id 不存在整个`ip`重新分配的逻辑就没有走... 没有走... 没有走...

```go
//TODO need to break this function down(comments from CR)
func (c *IPAMContext) nodeInit() error {
...
	usedIPs, err := c.getLocalPodsWithRetry()
	log.Debugf("getLocalPodsWithRetry() found %d used IPs.", len(usedIPs))
...
	for _, ip := range usedIPs {
		if ip.Container == "" {
			log.Infof("Skipping Pod %s, Namespace %s, due to no matching container", ip.Name, ip.Namespace)
			continue
		}
...
	}
	return nil
}
```

因为 ipamd 发现我们有大量 ip 申请了,但是没有用 ipamd 处于节约考虑帮我们释放了, 下面就是释放的日志了.

```
2019-11-26T02:47:06.317Z [DEBUG]	nodeIPPoolReconcile: skipping because time since last 51.08553629s <= 1m0s
2019-11-26T02:47:08.818Z [DEBUG]	IP pool stats: total = 28, used = 0, c.maxIPsPerENI = 14
2019-11-26T02:47:08.818Z [DEBUG]	IP pool is NOT too low: available (28) >= ENI target (1) * addrsPerENI (14)
2019-11-26T02:47:08.818Z [DEBUG]	IP pool stats: total = 28, used = 0, c.maxIPsPerENI = 14
2019-11-26T02:47:08.818Z [DEBUG]	It might be possible to remove extra ENIs because available (28) > ENI target (1) * addrsPerENI (14):
2019-11-26T02:47:08.818Z [DEBUG]	ENI eni-0debffa6dcf067b1b cannot be deleted because it is primary
2019-11-26T02:47:08.818Z [DEBUG]	getDeletableENI: found a deletable ENI eni-08bafec9495ebc6df
2019-11-26T02:47:08.818Z [INFO]	RemoveUnusedENIFromStore eni-08bafec9495ebc6df: IP address pool stats: free 14 addresses, total: 14, assigned: 0
2019-11-26T02:47:08.818Z [DEBUG]	Start freeing ENI eni-08bafec9495ebc6df
2019-11-26T02:47:08.818Z [INFO]	Trying to free ENI: eni-08bafec9495ebc6df
2019-11-26T02:47:08.930Z [DEBUG]	Found ENI eni-08bafec9495ebc6df attachment id: eni-attach-0dc80c1727c8163a8
2019-11-26T02:47:09.398Z [INFO]	Successfully detached ENI: eni-08bafec9495ebc6df
2019-11-26T02:47:09.398Z [DEBUG]	Trying to delete ENI: eni-08bafec9495ebc6df
2019-11-26T02:47:09.550Z [DEBUG]	Not able to delete ENI yet (attempt 1/20): InvalidParameterValue: Network interface 'eni-08bafec9495ebc6df' is currently in use.
	status code: 400, request id: de8ef372-0567-4b35-8c6d-3f7011089921
2019-11-26T02:47:14.868Z [INFO]	Successfully deleted ENI: eni-08bafec9495ebc6df
2019-11-26T02:47:14.868Z [INFO]	Successfully freed ENI: eni-08bafec9495ebc6df
```

## 尝试修复这个问题

修复方案1, 让 ipamd 可以正确的与 docker 通信.

```
root     15066  2.9  1.4 1241172 115768 ?      Ssl  09:02   0:12 /usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
```

```
guohao@pc ~ $ kubectl --kubeconfig ~/Downloads/kubeconfig -n kube-system describe ds aws-node
Name:           aws-node
Selector:       k8s-app=aws-node
Node-Selector:  <none>
Labels:         k8s-app=aws-node
Annotations:    deprecated.daemonset.template.generation: 12
                kubectl.kubernetes.io/last-applied-configuration:
                  {"apiVersion":"apps/v1","kind":"DaemonSet","metadata":{"annotations":{},"labels":{"k8s-app":"aws-node"},"name":"aws-node","namespace":"kub...
Desired Number of Nodes Scheduled: 2
Current Number of Nodes Scheduled: 2
Number of Nodes Scheduled with Up-to-date Pods: 1
Number of Nodes Scheduled with Available Pods: 2
Number of Nodes Misscheduled: 0
Pods Status:  2 Running / 0 Waiting / 0 Succeeded / 0 Failed
Pod Template:
  Labels:           k8s-app=aws-node
  Service Account:  aws-node
  Containers:
   aws-node:
    Image:      602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon-k8s-cni:v1.5.3
    Port:       61678/TCP
    Host Port:  61678/TCP
    Requests:
      cpu:  10m
    Environment:
      AWS_VPC_K8S_CNI_LOGLEVEL:      trace
      AWS_VPC_K8S_CNI_EXTERNALSNAT:  true
      MY_NODE_NAME:                   (v1:spec.nodeName)
    Mounts:
      /host/etc/cni/net.d from cni-net-dir (rw)
      /host/opt/cni/bin from cni-bin-dir (rw)
      /host/var/log from log-dir (rw)
      /run/containerd/containerd.sock from dockersock (rw) 
```
`/run/containerd/containerd.sock from dockersock (rw)` 就是这里, 本是适配社区的 containerd 做了修改, 而我们自己的环境是用的 docker.

在重新看一下日志已经没有那个问题了.