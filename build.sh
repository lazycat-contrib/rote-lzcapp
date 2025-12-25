#!/bin/bash

# Rote 懒猫应用构建和发布脚本
# 用于自动化构建、镜像复制和发布流程

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 应用信息
APP_NAME="Rote"
APP_VERSION=$(grep "^version:" lzc-manifest.yml | awk '{print $2}')
PACKAGE_NAME="cloud.lazycat.app.rote"

# 镜像列表
IMAGES=(
    "rabithua/rote-backend:latest"
    "rabithua/rote-frontend:latest"
    "postgres:17"
)

# 打印函数
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# 检查必需文件
check_files() {
    print_header "检查必需文件"

    local files=("lzc-manifest.yml" "lzc-build.yml" "icon.png")
    local missing=0

    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            print_success "找到文件: $file"
        else
            print_error "缺少文件: $file"
            missing=1
        fi
    done

    if [ $missing -eq 1 ]; then
        print_error "请确保所有必需文件都存在"
        return 1
    fi

    # 检查 icon.png 尺寸
    if command -v identify &> /dev/null; then
        local icon_size=$(identify -format "%wx%h" icon.png 2>/dev/null || echo "unknown")
        if [ "$icon_size" = "512x512" ]; then
            print_success "图标尺寸正确: 512x512"
        else
            print_warning "图标尺寸: $icon_size (推荐: 512x512)"
        fi
    fi

    return 0
}

# 验证配置
validate_config() {
    print_header "验证配置文件"

    # 检查 YAML 语法
    if command -v yamllint &> /dev/null; then
        yamllint lzc-manifest.yml && print_success "manifest.yml 语法正确" || print_warning "manifest.yml 可能有语法问题"
        yamllint lzc-build.yml && print_success "lzc-build.yml 语法正确" || print_warning "lzc-build.yml 可能有语法问题"
    else
        print_info "未安装 yamllint，跳过 YAML 语法检查"
    fi

    # 检查必需字段
    grep -q "min_os_version:" lzc-manifest.yml && print_success "包含 min_os_version" || print_warning "缺少 min_os_version"
    grep -q "healthcheck:" lzc-manifest.yml && print_success "包含健康检查配置" || print_info "未配置健康检查"

    return 0
}

# 显示应用信息
show_info() {
    print_header "应用信息"

    echo -e "${BLUE}应用名称:${NC} $APP_NAME"
    echo -e "${BLUE}版本号:${NC} $APP_VERSION"
    echo -e "${BLUE}包名:${NC} $PACKAGE_NAME"
    echo ""
    echo -e "${BLUE}包含的镜像:${NC}"
    for img in "${IMAGES[@]}"; do
        echo -e "  - $img"
    done
    echo ""
    echo -e "${BLUE}配置信息:${NC}"
    echo -e "  - 数据库: PostgreSQL 17"
    echo -e "  - 数据库密码: rote_password_123 (默认)"
    echo -e "  - 前端端口: 80"
    echo -e "  - 后端端口: 3000"
    echo -e "  - API 路径: /api"
    echo ""
}

# 构建应用
build_app() {
    print_header "构建应用包"

    if ! check_files; then
        return 1
    fi

    local output_file="${APP_NAME}-${APP_VERSION}.lpk"

    print_info "开始构建: $output_file"

    if lzc-cli project build -o "$output_file"; then
        print_success "构建成功: $output_file"
        ls -lh "$output_file"
        return 0
    else
        print_error "构建失败"
        return 1
    fi
}

# 更新 manifest 中的镜像地址
update_manifest_image() {
    local old_image="$1"
    local new_image="$2"

    print_info "更新镜像: $old_image -> $new_image"

    # 更新 lzc-manifest.yml
    if [ -f "lzc-manifest.yml" ]; then
        sed -i.bak "s|image: ${old_image}|image: ${new_image}|g" lzc-manifest.yml
        print_success "已更新 lzc-manifest.yml"
    fi

    # 清理备份文件
    rm -f lzc-manifest.yml.bak
}

# 检查登录状态
check_login() {
    print_info "检查登录状态..."
    if lzc-cli appstore my-images &> /dev/null 2>&1; then
        print_success "已登录懒猫应用商店"
        return 0
    else
        print_warning "未登录懒猫应用商店"
        print_info "请先执行: lzc-cli appstore login"
        return 1
    fi
}

# 复制镜像到懒猫仓库
copy_images() {
    print_header "复制镜像到懒猫仓库"

    if ! check_login; then
        return 1
    fi

    local updated=0

    for img in "${IMAGES[@]}"; do
        print_info "复制镜像: $img"

        local result=$(lzc-cli appstore copy-image "$img" 2>&1)

        if echo "$result" | grep -q "lazycat-registry:"; then
            local new_image=$(echo "$result" | grep "lazycat-registry:" | sed 's/.*lazycat-registry: //')
            print_success "复制成功: $new_image"

            # 更新 manifest
            update_manifest_image "$img" "$new_image"
            updated=1
        else
            print_error "复制失败: $img"
            echo "$result"
            return 1
        fi
    done

    if [ $updated -eq 1 ]; then
        print_success "所有镜像已复制并更新到 manifest"
        print_warning "请重新构建应用以使用新镜像"
    fi

    return 0
}

# 发布到应用商店
publish_app() {
    print_header "发布到应用商店"

    if ! check_login; then
        return 1
    fi

    local lpk_file="${APP_NAME}-${APP_VERSION}.lpk"

    if [ ! -f "$lpk_file" ]; then
        print_error "找不到应用包: $lpk_file"
        print_info "请先构建应用"
        return 1
    fi

    print_info "发布应用包: $lpk_file"

    if lzc-cli appstore publish "$lpk_file"; then
        print_success "发布成功"
        print_info "请等待审核（通常需要 1-3 天）"
        return 0
    else
        print_error "发布失败"
        return 1
    fi
}

# 一键构建+发布
one_click_publish() {
    print_header "一键构建+发布流程"

    print_info "阶段 1/4: 初始构建（原始镜像）"
    if ! build_app; then
        print_error "阶段 1 失败"
        return 1
    fi

    echo ""
    print_info "阶段 2/4: 镜像复制（自动更新 manifest）"
    if ! copy_images; then
        print_error "阶段 2 失败"
        return 1
    fi

    echo ""
    print_info "阶段 3/4: 重新构建（新镜像）"
    if ! build_app; then
        print_error "阶段 3 失败"
        return 1
    fi

    echo ""
    print_info "阶段 4/4: 发布审核"
    if ! publish_app; then
        print_error "阶段 4 失败"
        return 1
    fi

    echo ""
    print_success "🎉 一键发布流程完成！"
    print_info "应用已提交审核，请等待 1-3 天"
}

# 主菜单
show_menu() {
    echo ""
    print_header "$APP_NAME v$APP_VERSION - 构建和发布工具"
    echo ""
    echo "1. 📦 构建应用 (Build)"
    echo "2. 🔧 镜像复制到懒猫仓库 (Copy Images)"
    echo "3. 📤 发布到应用商店 (Publish)"
    echo "4. 🚀 一键构建+镜像复制+发布 (One-Click)"
    echo "5. 📋 查看应用信息 (Info)"
    echo "6. ✅ 验证配置文件 (Validate)"
    echo "7. ❌ 退出 (Exit)"
    echo ""
    read -p "请选择操作 [1-7]: " choice

    case $choice in
        1)
            build_app
            ;;
        2)
            copy_images
            ;;
        3)
            publish_app
            ;;
        4)
            one_click_publish
            ;;
        5)
            show_info
            ;;
        6)
            check_files && validate_config
            ;;
        7)
            print_info "退出"
            exit 0
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
}

# 主程序
main() {
    # 检查是否在正确的目录
    if [ ! -f "lzc-manifest.yml" ]; then
        print_error "请在应用根目录运行此脚本"
        exit 1
    fi

    # 检查 lzc-cli
    if ! command -v lzc-cli &> /dev/null; then
        print_error "未找到 lzc-cli 命令"
        print_info "请先安装 LazyCat CLI 工具"
        exit 1
    fi

    # 如果有参数，直接执行对应功能
    if [ $# -gt 0 ]; then
        case $1 in
            build)
                build_app
                ;;
            copy)
                copy_images
                ;;
            publish)
                publish_app
                ;;
            all)
                one_click_publish
                ;;
            info)
                show_info
                ;;
            validate)
                check_files && validate_config
                ;;
            *)
                print_error "未知命令: $1"
                print_info "可用命令: build, copy, publish, all, info, validate"
                exit 1
                ;;
        esac
    else
        # 交互式菜单
        while true; do
            show_menu
        done
    fi
}

main "$@"
