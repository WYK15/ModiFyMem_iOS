//
//  main.m
//  dev-modifyMem
//
//  Created by wangyankun on 2020/6/22.
//  Copyright (c) 2020 ___ORGANIZATIONNAME___. All rights reserved.
//
/*
   mach_vm functions reference: http://www.opensource.apple.com/source/xnu/xnu-1456.1.26/osfmk/vm/vm_user.c
    
   OSX: clang -framework Foundation -o HippocampHairSalon_OSX main.m

   iOS: clang -isysroot `xcrun --sdk iphoneos --show-sdk-path` -arch armv7 -arch arm64 -mios-version-min=10.2 -framework Foundation -o HippocampHairSalon_iOS main.m
   Then: ldid -Sent.xml HippocampHairSalon_iOS
*/

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#import <Foundation/Foundation.h>

#if TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR // Imports from /usr/lib/system/libsystem_kernel.dylib

//读/拷贝一份内存区域地址并返回给调用者
extern kern_return_t
mach_vm_read(
        vm_map_t        map,
        mach_vm_address_t    addr,
        mach_vm_size_t        size,
        pointer_t        *data,
        mach_msg_type_number_t    *data_size);

// 用data写入地址
extern kern_return_t
mach_vm_write(
        vm_map_t            map,
        mach_vm_address_t        address,
        pointer_t            data,
        __unused mach_msg_type_number_t    size);

// 返回一个task地址map的区域的信息
extern kern_return_t
mach_vm_region(
        vm_map_t         map,
        mach_vm_offset_t    *address,
        mach_vm_size_t        *size,
        vm_region_flavor_t     flavor,
        vm_region_info_t     info,
        mach_msg_type_number_t    *count,
        mach_port_t        *object_name);

extern kern_return_t mach_vm_protect
(
 vm_map_t target_task,
 mach_vm_address_t address,
 mach_vm_size_t size,
 boolean_t set_maximum,
 vm_prot_t new_protection
 );

#else
#include <mach/mach_vm.h>
#endif

void startModifyMem();
void* findAimAddressFromAddrs(const void* address,size_t addressLen,int aim);
NSArray* showValidAddrOfPid(int pid,int aim);
void listAllProcess();
void findTimes(int pid,NSArray *arr,int value);
void printAddrArr(NSArray<NSNumber*> *arr);

void printAddrArr(NSArray<NSNumber*> *arr) {
    for (int i = 0;i < arr.count;i++) {
        printf("地址为:0x%lx\n",arr[i].longValue);
    }
}

static NSArray *AllProcesses(void) // Taken from http://forrst.com/posts/UIDevice_Category_For_Processes-h1H
{
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    size_t size;
    //1.得到有多少个进程，保存在size中
    int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
    struct kinfo_proc *process = NULL;
    struct kinfo_proc *newprocess = NULL;
    do{
        size += size / 10;
        //2. 申请size个process内存大小地址
        newprocess = realloc(process, size);
        if (!newprocess)
        {
            if (process)
            {
                free(process);
            }
            return nil;
        }
        process = newprocess;
        // 3. 再次发起调用，得到所有的进程，保存在process中(起始地址)
        st = sysctl(mib, miblen, process, &size, NULL, 0);
    }while (st == -1 && errno == ENOMEM);
    
    // sysctl返回0，代表sysctl执行成功
    if (st == 0)
    {
        if (size % sizeof(struct kinfo_proc) == 0)
        {
            
            int nprocess = size / sizeof(struct kinfo_proc);
            if (nprocess)
            {
                NSMutableArray * array = [[NSMutableArray alloc] init];
                for (int i = nprocess - 1; i >= 0; i--)
                {
                    NSString * processID = [[NSString alloc] initWithFormat:@"%d", process[i].kp_proc.p_pid];
                    NSString * processName = [[NSString alloc] initWithFormat:@"%s", process[i].kp_proc.p_comm];
                    NSDictionary * dictionary = [[NSDictionary alloc] initWithObjects:[NSArray arrayWithObjects:processID, processName, nil] forKeys:[NSArray arrayWithObjects:@"ProcessID", @"ProcessName", nil]];
                    [array addObject:dictionary];
                }
                free(process);
                return array;
            }
        }
    }
    return nil;
}

void* findAimAddressFromAddrs(const void* address,size_t addressLen,int aim) {
    return memmem(address, addressLen, &aim, sizeof(aim));
}


NSArray* showValidAddrOfPid(int pid,int aim) {
    NSMutableArray<NSNumber*> *array = [NSMutableArray arrayWithCapacity:500];
    kern_return_t kret;
    mach_port_t task; // type vm_map_t = mach_port_t in mach_types.defs
    //获取到pid对应到的task
    if ((kret = task_for_pid(mach_task_self(), pid, &task)) != KERN_SUCCESS)
    {
        printf("task_for_pid() failed, error %d: %s. Forgot to run as root?\n", kret, mach_error_string(kret));
        exit(1);
    }
    
    printf("开始遍历pid为 %d 的内存中,值为 %d 的地址如下：\n",pid,aim);
    mach_vm_offset_t address_index = 0;
    mach_vm_size_t size ;
    vm_region_basic_info_data_64_t region_info;
    mach_msg_type_number_t number = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t name;
    //利用mach_vm_region 遍历task的对应的地址，和地址的protection情况。每个页的内存大小为size。
    while (mach_vm_region(task, &address_index, &size, VM_REGION_BASIC_INFO, (vm_region_info_t)&region_info, &number, &name) == KERN_SUCCESS) {
        //printf("%lld\n",address_index);
        //获取读取内存的内存区域的信息
        vm_prot_t protect = region_info.protection;
        
        pointer_t data_buffer;
        mach_msg_type_number_t buffersize = size;
        //利用mach_vm_read读取address地址的内容，读取到data_buffer中,data_buffer长度也为“属于此进程的的address_index”开始的页大小
        //直接在start指针指向的存储单元里查找find指针指向的字符串,
        // 如果找到,返回指向子串的指针,否则返回空指针.
        if (mach_vm_read(task, (mach_vm_address_t)address_index, size, &data_buffer, &buffersize) == KERN_SUCCESS) {
            void *subStringAddress = NULL;
           // if ((subStringAddress = memmem((const void*)data_buffer, buffersize, &aim, sizeof(aim))) != NULL) {
            if((subStringAddress = findAimAddressFromAddrs((const void*)data_buffer, buffersize, aim)) != NULL) {
                //区分64位和32位，地址的大小不同。64位地址为long,32位为int
                //CGFloat只是对float或double的typedef定义，在64位机器上，CGFloat定义为double类型。在32位机器上为float.
                //#if CGFLOAT_IS_DOUBLE
//#if CGFLOAT_IS_DOUBLE
                long realAddress = (long)subStringAddress - (long)data_buffer + (long)address_index;
//                if (protect & VM_PROT_WRITE) {
                    printf("64位：0x%lx的地址的值为%d，此块内存允许写与否：%d\n",realAddress,aim,(protect & VM_PROT_WRITE) != 0);
                                   [array addObject:[NSNumber numberWithLong:realAddress]];
//                }
//#else
//                unsigned int realAddress = (unsigned int)subStringAddress - (unsigned int)data_buffer + (unsigned int)address_index;
//                printf("32位：0x%x的地址的值为%d，此块内存允许写与否：%d\n",realAddress,aim,(protect & VM_PROT_WRITE) != 0);
//                [array addObject:[NSString stringWithFormat:@"%x,%d,%d",realAddress,buffersize,(protect & VM_PROT_WRITE) != 0]];
//#endif
            }
        }
        
        address_index += size; //address_index移动
    }
    return array;
}

void listAllProcess() {
    // 1. 获取当前运行所有进程的id和name，打印出来以供选择
    NSArray *processArr = AllProcesses();
    for (NSDictionary *dic in processArr) {
        NSLog(@"pid : %@,proname : %@",dic[@"ProcessID"],dic[@"ProcessName"]);
    }
}

void changeVOfAddr(int pid) {
    while (getchar() != '\n') {
        continue;
    }
    printf("Enter the address of modification: ");
    mach_vm_address_t modAddress;
    scanf("0x%llx", &modAddress);
    printf("你输入的地址为:%llx\n",modAddress);
    while (getchar() != '\n') continue; // clear buffer
    printf("Enter the new value: ");
    int newValue; // change type: unsigned int, long, unsigned long, etc. Should be customizable!
    scanf("%d", &newValue);
    
    kern_return_t kret;
    mach_port_t task;
    
    if ((kret = task_for_pid(mach_task_self(), pid, &task)) != KERN_SUCCESS) {
        printf("task_for_pid 失败\n");
        startModifyMem();
        return;
    }
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_vm_address_t dummyadr = modAddress;
    mach_port_t object_name = 0;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    if ( (kret = mach_vm_region(task, &dummyadr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count,&object_name)) != KERN_SUCCESS) {
        printf("mach_vm_region error ,error code :%d\n",kret);
    }
    
    task_suspend(task);
    if ( (kret = mach_vm_protect(task, modAddress, sizeof(newValue), FALSE, VM_PROT_WRITE | VM_PROT_READ | VM_PROT_COPY)) != KERN_SUCCESS) {
        printf("mach_vm_protect failed with error %d\n", kret);
        exit(1);
    }
    if ((kret = mach_vm_write(task, modAddress, (pointer_t)&newValue, sizeof(newValue))) != KERN_SUCCESS) {
         printf("mach_vm_write failed, error %d: %s\n", kret, mach_error_string(kret));
        exit(1);
    }else {
        printf("修改成功!!\n");
    }
    if ( (kret = mach_vm_protect(task, modAddress, sizeof(newValue), FALSE, info.protection))) {
        printf("mach_vm_protect failed with error %d\n", kret);
        exit(1);
    }
    task_resume(task);
}

//递归找
void findTimes(int pid,NSArray<NSNumber*> *arr,int value) {
    int aim;
    printf("------选项：------\n* -1,重新进行，回到进程开始处\n* -2,准备改变值\n* 3,继续输入需要查找的值(改变后的值)，这会逐渐锁定最终的修改地址\n* 0,结束进程\n");
    scanf("%d",&aim);
    if (aim == -1) {
        startModifyMem();
    }else if(aim == -2){
        changeVOfAddr(pid);
    }else if (aim == 0) {
        printf("结束进程   \n");
        exit(0);
    }else{
        printf("请输入改变后的值 : ");
        scanf("%d",&aim);
        NSMutableArray<NSNumber*> *newArr = [NSMutableArray arrayWithCapacity:arr.count];
        
        //取交集
        NSArray *AddressOfNewValue = showValidAddrOfPid(pid, aim);
        for (int i = 0;i < AddressOfNewValue.count;i++) {
            if ([arr indexOfObject:AddressOfNewValue[i]] != NSNotFound) {
                [newArr addObject:AddressOfNewValue[i]];
                printf("**********\n");
            }
        }
        
        if (newArr.count > 0) {
            printf("筛选后的地址为 ：\n");
            printAddrArr(newArr);
            findTimes(pid,newArr, aim);
        }else {
            printf("没有在此进程中找到值\n");
            startModifyMem();
        }
    }
}

void startModifyMem() {
    listAllProcess();
    
    int pid,value;
    printf("输入pid:");
    scanf("%d",&pid);
    
    printf("输入查找的值:");
    scanf("%d",&value);
    
    //根据pid和value先筛选一次地址
    NSArray<NSNumber*> *validArr = showValidAddrOfPid(pid,value);
    if(validArr.count > 0){
        printf("找到如下的地址值为 : %d\n",value);
        printAddrArr(validArr);
        findTimes(pid,validArr,value);
    }else {
        printf("没有在此进程中找到值\n");
        startModifyMem();
    }

}


int main (int argc, const char * argv[])
{

    @autoreleasepool
    {	
    	// insert code here...
        NSLog(@"*****修改内存******");
        
        startModifyMem();
        
    }
	return 0;
}


