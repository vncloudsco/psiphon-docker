#!/bin/bash

#==============================================================================
# Squid + Psiphon Proxy Setup Script
# Tự động triển khai hệ thống proxy 2 lớp với xác thực
#==============================================================================

set -e

# Màu sắc cho output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Biến mặc định
USERNAME=""
PASSWORD=""
SQUID_PORT="3128"
DEVICE_REGION="IN"
EGRESS_REGION="SG"
AUTO_START=false
INTERACTIVE=true

#==============================================================================
# Hàm hiển thị
#==============================================================================

print_banner() {
    echo -e "${BLUE}"
    echo "=================================================================="
    echo "   Squid + Psiphon Proxy - Auto Setup Script"
    echo "=================================================================="
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

show_help() {
    cat << EOF
Sử dụng: $0 [OPTIONS]

Triển khai hệ thống Squid + Psiphon proxy với một lệnh duy nhất.

OPTIONS:
    -u, --username USERNAME     Username cho Squid proxy (mặc định: random)
    -p, --password PASSWORD     Password cho Squid proxy (mặc định: random)
    -P, --port PORT            Port cho Squid proxy (mặc định: 3128)
    -d, --device-region REGION  Device region cho Psiphon (mặc định: IN)
    -e, --egress-region REGION  Egress region cho Psiphon (mặc định: SG)
    -s, --start                Tự động khởi động sau khi setup
    -y, --yes                  Không hỏi, chạy tự động
    -h, --help                 Hiển thị trợ giúp này

VÍ DỤ:
    # Setup với username/password tùy chỉnh
    $0 -u admin -p MySecurePass123

    # Setup với random credentials và tự động khởi động
    $0 -s

    # Setup đầy đủ không cần confirm
    $0 -u myuser -p mypass -d US -e JP -s -y

    # Setup và chỉ định port khác
    $0 -u admin -p admin123 -P 8888 -s

REGIONS hỗ trợ (Psiphon):
    AT, AU, BE, BR, CA, CH, CZ, DE, DK, ES, FI, FR, GB, ID, IE, IN, IT, 
    JP, LT, NL, NO, PL, RO, RS, SE, SG, US

EOF
    exit 0
}

#==============================================================================
# Hàm tiện ích
#==============================================================================

generate_random_string() {
    local length=$1
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

generate_credentials() {
    if [ -z "$USERNAME" ]; then
        USERNAME="user_$(generate_random_string 6)"
        print_info "Generated username: $USERNAME"
    fi
    
    if [ -z "$PASSWORD" ]; then
        PASSWORD="$(generate_random_string 16)"
        print_info "Generated password: $PASSWORD"
    fi
}

check_dependencies() {
    print_info "Kiểm tra dependencies..."
    
    # Kiểm tra Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker chưa được cài đặt!"
        echo "Vui lòng cài đặt Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    # Kiểm tra Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        print_error "Docker Compose chưa được cài đặt!"
        echo "Vui lòng cài đặt Docker Compose: https://docs.docker.com/compose/install/"
        exit 1
    fi
    
    # Kiểm tra htpasswd
    if ! command -v htpasswd &> /dev/null; then
        print_info "Cài đặt apache2-utils để tạo password file..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y apache2-utils
        elif command -v yum &> /dev/null; then
            sudo yum install -y httpd-tools
        elif command -v apk &> /dev/null; then
            sudo apk add --no-cache apache2-utils
        else
            print_error "Không thể cài đặt htpasswd tự động!"
            echo "Vui lòng cài đặt apache2-utils hoặc httpd-tools thủ công."
            exit 1
        fi
    fi
    
    print_success "Tất cả dependencies đã sẵn sàng"
}

create_directories() {
    print_info "Tạo cấu trúc thư mục..."
    mkdir -p squid/cache squid/logs psiphon/config
    print_success "Đã tạo thư mục"
}

create_password_file() {
    print_info "Tạo file xác thực cho Squid..."
    
    # Tạo password file
    htpasswd -cb squid/passwords "$USERNAME" "$PASSWORD" > /dev/null 2>&1
    chmod 644 squid/passwords
    
    print_success "Đã tạo tài khoản: $USERNAME"
}

update_docker_compose() {
    print_info "Cập nhật cấu hình Docker Compose..."
    
    # Backup nếu file đã tồn tại
    if [ -f docker-compose.yaml ]; then
        cp docker-compose.yaml docker-compose.yaml.backup
        print_info "Đã backup docker-compose.yaml"
    fi
    
    # Cập nhật environment variables cho Psiphon
    sed -i "s/DEVICE_REGION=.*/DEVICE_REGION=$DEVICE_REGION/" docker-compose.yaml
    sed -i "s/EGRESS_REGION=.*/EGRESS_REGION=$EGRESS_REGION/" docker-compose.yaml
    
    # Cập nhật port nếu khác 3128
    if [ "$SQUID_PORT" != "3128" ]; then
        sed -i "s/\"3128:3128\"/\"$SQUID_PORT:3128\"/" docker-compose.yaml
    fi
    
    print_success "Đã cập nhật cấu hình"
}

start_services() {
    print_info "Khởi động Docker containers..."
    
    # Stop containers cũ nếu có
    docker-compose down > /dev/null 2>&1 || true
    
    # Start containers
    docker-compose up -d
    
    print_success "Containers đã được khởi động"
}

wait_for_services() {
    print_info "Đợi services khởi động hoàn tất..."
    
    local max_wait=30
    local count=0
    
    while [ $count -lt $max_wait ]; do
        if docker-compose ps | grep -q "Up"; then
            if docker exec psiphon pgrep -f psiphon > /dev/null 2>&1; then
                print_success "Services đã sẵn sàng"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
        echo -n "."
    done
    
    echo ""
    print_error "Timeout waiting for services"
    return 1
}

test_proxy() {
    print_info "Kiểm tra kết nối proxy..."
    
    sleep 3
    
    local test_url="http://ipinfo.io"
    local proxy_url="http://$USERNAME:$PASSWORD@localhost:$SQUID_PORT"
    
    if curl -s -x "$proxy_url" "$test_url" > /dev/null 2>&1; then
        print_success "Proxy hoạt động tốt!"
        
        # Hiển thị thông tin IP
        echo ""
        echo -e "${BLUE}=== Thông tin kết nối ===${NC}"
        curl -s -x "$proxy_url" "$test_url" | grep -E "ip|city|country|region" | head -5
        return 0
    else
        print_error "Không thể kết nối qua proxy"
        echo "Kiểm tra logs: docker-compose logs"
        return 1
    fi
}

save_credentials() {
    local cred_file=".proxy_credentials"
    
    cat > "$cred_file" << EOF
# Proxy Credentials
# Generated: $(date)

PROXY_HOST=localhost
PROXY_PORT=$SQUID_PORT
PROXY_USERNAME=$USERNAME
PROXY_PASSWORD=$PASSWORD

# URL format
PROXY_URL=http://$USERNAME:$PASSWORD@localhost:$SQUID_PORT

# Psiphon Settings
DEVICE_REGION=$DEVICE_REGION
EGRESS_REGION=$EGRESS_REGION
EOF
    
    chmod 600 "$cred_file"
    print_success "Đã lưu credentials vào $cred_file"
}

show_summary() {
    echo ""
    echo -e "${GREEN}=================================================================="
    echo "                    SETUP HOÀN TẤT!"
    echo -e "==================================================================${NC}"
    echo ""
    echo -e "${BLUE}📋 THÔNG TIN PROXY:${NC}"
    echo "   Host:     localhost (hoặc IP server của bạn)"
    echo "   Port:     $SQUID_PORT"
    echo "   Username: $USERNAME"
    echo "   Password: $PASSWORD"
    echo ""
    echo -e "${BLUE}🌍 PSIPHON SETTINGS:${NC}"
    echo "   Device Region: $DEVICE_REGION"
    echo "   Egress Region: $EGRESS_REGION"
    echo ""
    echo -e "${BLUE}🔧 CÁC LỆNH HỮU ÍCH:${NC}"
    echo "   # Xem logs"
    echo "   docker-compose logs -f"
    echo ""
    echo "   # Test proxy"
    echo "   curl -x http://$USERNAME:$PASSWORD@localhost:$SQUID_PORT http://ipinfo.io"
    echo ""
    echo "   # Restart services"
    echo "   docker-compose restart"
    echo ""
    echo "   # Stop services"
    echo "   docker-compose down"
    echo ""
    echo "   # Thêm user mới"
    echo "   htpasswd squid/passwords newuser"
    echo "   docker-compose restart squid"
    echo ""
    echo -e "${BLUE}📁 FILES QUAN TRỌNG:${NC}"
    echo "   Config:      squid/squid.conf"
    echo "   Passwords:   squid/passwords"
    echo "   Credentials: .proxy_credentials"
    echo "   Logs:        squid/logs/"
    echo ""
    echo -e "${YELLOW}⚠️  LƯU Ý BẢO MẬT:${NC}"
    echo "   - Đổi password định kỳ"
    echo "   - Không chia sẻ credentials"
    echo "   - File .proxy_credentials chứa thông tin nhạy cảm"
    echo "   - Xem hướng dẫn chi tiết: README-SQUID.md"
    echo ""
    echo -e "${GREEN}=================================================================="
    echo -e "${NC}"
}

#==============================================================================
# Parse arguments
#==============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--username)
                USERNAME="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
                shift 2
                ;;
            -P|--port)
                SQUID_PORT="$2"
                shift 2
                ;;
            -d|--device-region)
                DEVICE_REGION="$2"
                shift 2
                ;;
            -e|--egress-region)
                EGRESS_REGION="$2"
                shift 2
                ;;
            -s|--start)
                AUTO_START=true
                shift
                ;;
            -y|--yes)
                INTERACTIVE=false
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
}

#==============================================================================
# Main
#==============================================================================

main() {
    parse_arguments "$@"
    
    print_banner
    
    # Generate credentials nếu chưa có
    generate_credentials
    
    # Confirm nếu interactive mode
    if [ "$INTERACTIVE" = true ]; then
        echo -e "${YELLOW}Cấu hình sẽ được triển khai:${NC}"
        echo "  Username:      $USERNAME"
        echo "  Password:      $PASSWORD"
        echo "  Squid Port:    $SQUID_PORT"
        echo "  Device Region: $DEVICE_REGION"
        echo "  Egress Region: $EGRESS_REGION"
        echo ""
        read -p "Tiếp tục? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            print_info "Đã hủy"
            exit 0
        fi
    fi
    
    echo ""
    
    # Thực hiện setup
    check_dependencies
    create_directories
    create_password_file
    update_docker_compose
    save_credentials
    
    # Start services nếu được yêu cầu
    if [ "$AUTO_START" = true ]; then
        start_services
        wait_for_services
        test_proxy
    else
        echo ""
        print_info "Setup hoàn tất. Để khởi động services, chạy:"
        echo "  docker-compose up -d"
        echo ""
        print_info "Hoặc chạy lại với option -s để tự động khởi động:"
        echo "  $0 -s"
    fi
    
    # Show summary
    echo ""
    show_summary
}

# Run main function
main "$@"
