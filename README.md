# Wocyber_S2
飞牛适配S2镜像补丁
智小惠S2刷fnos操作步骤
一、前提条件
准备一台windows主机，并拷贝/准备好下述软件及工具：
1.瑞芯微RK驱动程序DriverAssitant_v5.1.1包
<img width="159" height="32" alt="image" src="https://github.com/user-attachments/assets/4e299719-28ae-4881-9e83-dbf486564b3c" />
2.刷机工具包
<img width="408" height="53" alt="image" src="https://github.com/user-attachments/assets/f3a4a98b-7124-40df-b505-55699db6aa49" />
3.顶针，用于按压reset孔
<img width="85" height="38" alt="image" src="https://github.com/user-attachments/assets/4eb4e314-3158-4d0d-be5d-36404649c80b" />
4.刷机包
<img width="416" height="40" alt="image" src="https://github.com/user-attachments/assets/976fbeec-c126-42c2-a6dc-bd3519b3db9a" />
5.USB刷机线：USB AtoA（双公头）数据线
<img width="155" height="140" alt="image" src="https://github.com/user-attachments/assets/4c9977c4-9c37-4ba1-817f-936b6b8e2c78" />
6.MobaXterm_Personal工具
<img width="211" height="35" alt="image" src="https://github.com/user-attachments/assets/cfcf0727-6bd6-4f81-bf8e-25d7d001a87b" />


所有的压缩包都需要解压后使用


二、安装&刷机
驱动安装：
打开DriverAssitant文件夹，运行DriverInstall.exe
<img width="396" height="200" alt="image" src="https://github.com/user-attachments/assets/e7c8a553-8d27-4640-95eb-1c5d93b99927" />

先点【驱动卸载】，删除之前驱动，处理完后，再点【驱动安装】
<img width="396" height="200" alt="image" src="https://github.com/user-attachments/assets/a610e8d3-4e74-4355-a4fd-174d392c02ec" />


下面开始刷机，提醒：刷机全程禁止断电、拔USB线，断连可能导致设备变砖！！！
【Loader】模式烧录：
默认用此模式。
1.运行RKDevTool.exe。
2.不接电源，USB数据线一端先接电脑USB口，之后用顶针插入设备后面板上的reset孔并按压顶住内部按钮，最后再把USB线的另一端插到设备的USB口上，观察ERKDevTool界面底部，出现提示“发现一个LOADER设备”，这时可以松开并取出顶针。
3.“下载镜像”菜单页，去掉勾选的第一行“Boot”，只勾选第二行“system”，选择存放“update_0822.img”文件的路径（要先解压update_0822.img.zip文件获取），并要勾选“强制按地址写”，最后点击“执行”。
4.等待烧录下载完成后设备会自动重启。

步骤二、三图例：
<img width="555" height="264" alt="image" src="https://github.com/user-attachments/assets/e5512658-bc1c-4d93-b683-729f22fa1ffa" />
成功烧录图例：
<img width="555" height="264" alt="image" src="https://github.com/user-attachments/assets/f021343c-546a-49c2-aedc-a55515b7b250" />

【MASKROM】模式烧录：
Loader进不去的情况下，使用此方法。
该方法需要拆机，拆机方法参考附录。
1.设备拆机后，在板子上找到Uboot按键位置（如没有找到按键，可用镊子或导电线短接）。
2.先按下按键或者短接两点，再接入USB数据线，等RKDevTool.exe工具界面底部出现“发现一个MASKROM设备”的提示，这时可以松开按键或短接工具。
3.RKDevTool.exe的“下载镜像”页面，需要同时勾选“Boot”“system”，然后选择对应文件（Boot文件在RKDevTool文件夹的RK3568文件夹里），并要勾选“强制按地址写”，最后点击“执行”刷机，直到右侧提示下载完成。
拆机后Uboot位置图例：
<img width="244" height="325" alt="image" src="https://github.com/user-attachments/assets/4e7cf57d-ea3e-4e6b-9607-987f98fb051a" />
<img width="243" height="324" alt="image" src="https://github.com/user-attachments/assets/8106388c-cdb0-45e4-b73b-a238efef4e98" />               

步骤3图例：
<img width="584" height="278" alt="image" src="https://github.com/user-attachments/assets/981f8944-20f9-425d-b797-286cc988816c" />
烧录成功图例：
<img width="583" height="278" alt="image" src="https://github.com/user-attachments/assets/a1bccdbf-bef6-4291-8fb6-99c80c4668ba" />
至此，fnos刷机完毕！！

三、安装补丁
1.电脑登录路由器管理后台找到fnos设备的IP，打开浏览器输入IP+5666（例：192.168.1.x:5666）进入fnos系统初始化设置界面配置账户及密码。
2.运行MobaXterm_Personal_22.1.exe。
3.创建会话选择SSH，在设置输入NAS主机IP地址，端口填写“22”。
4.输入第二步里进入fnos注册的账号及密码。
5.将解压好的install-1014文件夹拖到/home/anna/下。
执行命令：sudo bash /home/anna/install-1012/setup-boot-version-guard.sh（执行该命令需要再输入一次密码）。
操作完后，日后正常飞牛升级即可。
常规事项排查：
#烧录时，是否需要接入电源？
答：不需要。
#烧录能否使用普通type-C线
答：不能，因为兼容性不统一。
#烧录注意事项
答：确定设备连接完整，烧录过程中严禁触碰烧录连接、与烧录线。
#烧录过程失败，该如何操作？
答：烧录过程中，如遇烧录失败，可再按照步骤重新烧录，如果发现不了，就需要拆机烧录。
#飞牛app如何下载？
答：手机应用商店搜索“飞牛”下载安装。
#飞牛该如何使用？
答：可在官网“https://help.fnnas.com/”寻找相关使用方法。
#飞牛升级需要多久
答：因为网络环境不一（参考数值：环境网络为百兆网络，升级使用时间为20分钟）

            



