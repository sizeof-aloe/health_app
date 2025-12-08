/*
 * MAX30102 + LCD + DS1302 + HC-05 (UART0)
 * Solution: Fixed LCD Garbage & Shifting Issue (Proper 4-bit Init)
 */

#include <mega128.h>
#include <delay.h>

#define MYUBRR 103 // 9600bps

// --- I2C Macros ---
#define TWINT 7
#define TWEA  6
#define TWSTA 5
#define TWSTO 4
#define TWEN  2

#define CS02  2
#define WGM01 3
#define OCIE0 1

// --- UART0 Macros ---
#define RXEN0 4
#define TXEN0 3
#define UDRE0 5
#define UCSZ01 2
#define UCSZ00 1

#define MAX30102_ADDR 0xAE 
#define LCD_I2C_ADDR  (0x27 << 1) 

// DS1302 Pins
#define DS1302_PORT     PORTB
#define DS1302_DDR      DDRB
#define DS1302_PIN      PINB
#define DS1302_RST_PIN  2
#define DS1302_IO_PIN   1
#define DS1302_SCLK_PIN 0

// Registers & Flags
#define REG_FIFO_WR_PTR 0x04
#define REG_FIFO_OVF_CNT 0x05
#define REG_FIFO_RD_PTR 0x06
#define REG_FIFO_DATA 0x07 
#define REG_FIFO_CONFIG 0x08
#define REG_MODE_CONFIG 0x09
#define REG_SPO2_CONFIG 0x0A
#define REG_LED1_PA 0x0C
#define REG_LED2_PA 0x0D

// LCD Control Macros (명확한 정의)
#define LCD_EN 0x04  // Enable Bit
#define LCD_RW 0x02  // Read/Write Bit
#define LCD_RS 0x01  // Register Select Bit
#define LCD_BL 0x08  // Backlight Bit

// Filter
#define SCALE_SHIFT 10
#define LPF_B1 819  
#define LPF_A0 205   
#define HPF_B1 819 
#define HPF_A0 921 
#define HPF_A1 921
#define FINGER_THRESHOLD 30000 
#define FINGER_COOLDOWN_MS 300
#define EDGE_THRESHOLD -5  

// --- 전역 버퍼 ---
char g_buf[20]; 

volatile unsigned long timer0_millis = 0;
int print_counter = 0;
long current_bpm = 0, current_spo2 = 0;
unsigned char rtc_hour = 0, rtc_min = 0, rtc_sec = 0;
unsigned char rtc_year = 0, rtc_month = 0, rtc_day = 0;

// ==========================================
// Utils
// ==========================================
void long_to_str(long num) {
    long temp = num;
    int i = 0, j;
    char t;
    if (num == 0) { g_buf[0] = '0'; g_buf[1] = '\0'; return; }
    if (num < 0) { g_buf[i++] = '-'; temp = -num; }
    while (temp > 0) { g_buf[i++] = (temp % 10) + '0'; temp /= 10; }
    g_buf[i] = '\0';
    j = (num < 0) ? 1 : 0; i--;
    while (j < i) { t = g_buf[j]; g_buf[j] = g_buf[i]; g_buf[i] = t; j++; i--; }
}

unsigned char bcd_to_dec(unsigned char val) { return (val / 16 * 10) + (val % 16); }
unsigned char dec_to_bcd(unsigned char val) { return (val / 10 * 16) + (val % 10); }

// ==========================================
// Drivers
// ==========================================
interrupt [TIM0_COMP] void timer0_comp_isr(void) { timer0_millis++; }
void millis_init(void) { TCCR0 = (1 << WGM01) | (1 << CS02); OCR0 = 249; TIMSK |= (1 << OCIE0); #asm("sei") }
unsigned long millis(void) { unsigned long m; #asm("cli") m = timer0_millis; #asm("sei") return m; }

// UART0
void bt_init(void) { 
    UBRR0H = 0; UBRR0L = MYUBRR; 
    UCSR0B = (1 << RXEN0) | (1 << TXEN0); 
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00); 
}
void bt_transmit(char data) { while (!(UCSR0A & (1 << UDRE0))); UDR0 = data; }
void bt_str(char* str) { while (*str) bt_transmit(*str++); }
void bt_long(long val) { long_to_str(val); bt_str(g_buf); } 
void bt_2digits(unsigned char val) { if (val < 10) bt_transmit('0'); bt_long((long)val); }

// TWI & DS1302
void twi_start(void) { TWCR=(1<<TWINT)|(1<<TWSTA)|(1<<TWEN); while(!(TWCR&(1<<TWINT))); }
void twi_stop(void) { TWCR=(1<<TWINT)|(1<<TWSTO)|(1<<TWEN); }
void twi_write(unsigned char d) { TWDR=d; TWCR=(1<<TWINT)|(1<<TWEN); while(!(TWCR&(1<<TWINT))); }
unsigned char twi_read_ack(void) { TWCR=(1<<TWINT)|(1<<TWEN)|(1<<TWEA); while(!(TWCR&(1<<TWINT))); return TWDR; }
unsigned char twi_read_nack(void) { TWCR=(1<<TWINT)|(1<<TWEN); while(!(TWCR&(1<<TWINT))); return TWDR; }

void DS1302_init(void) { DS1302_DDR|=(1<<2)|(1<<0); DS1302_PORT&=~((1<<2)|(1<<0)); }
void DS1302_wb(unsigned char b) {
    unsigned char i; DS1302_DDR|=(1<<1);
    for(i=0; i<8; i++) {
        if(b&1) DS1302_PORT|=(1<<1); else DS1302_PORT&=~(1<<1);
        delay_us(2); DS1302_PORT|=(1<<0); delay_us(2); DS1302_PORT&=~(1<<0); delay_us(2); b>>=1;
    }
}
unsigned char DS1302_rb(void) {
    unsigned char i, b=0; DS1302_DDR&=~(1<<1); DS1302_PORT&=~(1<<1);
    for(i=0; i<8; i++) {
        if(DS1302_PIN&(1<<1)) b|=(1<<i);
        delay_us(2); DS1302_PORT|=(1<<0); delay_us(2); DS1302_PORT&=~(1<<0); delay_us(2);
    } return b;
}
unsigned char DS1302_read(unsigned char a) {
    unsigned char d; DS1302_PORT&=~(1<<0); DS1302_PORT|=(1<<2); delay_us(2);
    DS1302_wb(a); d=DS1302_rb(); DS1302_PORT&=~(1<<2); return d;
}
void get_time(void) {
    rtc_sec = bcd_to_dec(DS1302_read(0x81) & 0x7F);
    rtc_min = bcd_to_dec(DS1302_read(0x83));
    rtc_hour = bcd_to_dec(DS1302_read(0x85) & 0x3F);            
    rtc_day = bcd_to_dec(DS1302_read(0x87));   
    rtc_month = bcd_to_dec(DS1302_read(0x89)); 
    rtc_year = bcd_to_dec(DS1302_read(0x8D));  
}

// --- LCD Functions (Fixed) ---
void lcd_i2c(unsigned char *b, unsigned char l) { 
    unsigned char i; 
    twi_start(); twi_write(LCD_I2C_ADDR); 
    for(i=0;i<l;i++) twi_write(b[i]); 
    twi_stop(); 
}

// [중요] 초기화용: 상위 4비트(반쪽)만 전송하는 함수
void lcd_half_cmd(unsigned char c) {
    unsigned char b[2];
    b[0] = (c & 0xF0) | LCD_EN | LCD_BL; // Enable High
    b[1] = (c & 0xF0) | LCD_BL;          // Enable Low (RS=0)
    lcd_i2c(b, 2);
}

// 일반 명령어 (RS=0)
void lcd_cmd(unsigned char c) {
    unsigned char b[4];
    // Upper Nibble
    b[0] = (c & 0xF0) | LCD_EN | LCD_BL; 
    b[1] = (c & 0xF0) | LCD_BL;
    // Lower Nibble
    b[2] = ((c << 4) & 0xF0) | LCD_EN | LCD_BL;
    b[3] = ((c << 4) & 0xF0) | LCD_BL;
    lcd_i2c(b, 4);
}

// 데이터 (RS=1)
void lcd_data(unsigned char d) {
    unsigned char b[4];
    // Upper Nibble
    b[0] = (d & 0xF0) | LCD_EN | LCD_RS | LCD_BL; 
    b[1] = (d & 0xF0) | LCD_RS | LCD_BL;
    // Lower Nibble
    b[2] = ((d << 4) & 0xF0) | LCD_EN | LCD_RS | LCD_BL;
    b[3] = ((d << 4) & 0xF0) | LCD_RS | LCD_BL;
    lcd_i2c(b, 4);
}

void lcd_gotoxy(unsigned char x, unsigned char y) { lcd_cmd(0x80|((0x40*y)+x)); }
void lcd_str(char *s) { while(*s) lcd_data(*s++); }
void lcd_long(long v) { long_to_str(v); lcd_str(g_buf); }

void lcd_init(void) {
    delay_ms(50); 
    // [중요] 초기화 매직 시퀀스 (4비트 모드 진입 전)
    // 8비트 모드라고 착각하는 LCD에게 3번 반복해서 리셋 신호 보냄
    lcd_half_cmd(0x30); delay_ms(10); 
    lcd_half_cmd(0x30); delay_ms(1); 
    lcd_half_cmd(0x30); delay_ms(1); 
    
    // [중요] 4비트 모드로 전환 (반쪽만 전송해야 함!)
    lcd_half_cmd(0x20); delay_ms(1); 

    // 이제부터 정상 명령 가능
    lcd_cmd(0x28); // 4-bit, 2 lines, 5x7 font
    lcd_cmd(0x0C); // Display On
    lcd_cmd(0x06); // Entry Mode (커서 자동 이동, 밀림 방지)
    lcd_cmd(0x01); // Clear Display
    delay_ms(2);   
}

// MAX30102
void max_wr(unsigned char r, unsigned char v) { twi_start(); twi_write(MAX30102_ADDR); twi_write(r); twi_write(v); twi_stop(); }
unsigned char max_rd(unsigned char r) {
    unsigned char v; twi_start(); twi_write(MAX30102_ADDR); twi_write(r);
    twi_start(); twi_write(MAX30102_ADDR|1); v=twi_read_nack(); twi_stop(); return v;
}

// Logic
typedef struct { long last; char init; } LPF;
long lpf(LPF* f, long v) { if(!f->init) { f->last=v; f->init=1; } else f->last=(LPF_A0*v + LPF_B1*f->last)>>SCALE_SHIFT; return f->last; }
typedef struct { long lf, lr; char init; } HPF;
long hpf(HPF* f, long v) { if(!f->init) { f->lf=0; f->lr=v; f->init=1; } else { f->lf=(HPF_A0*v - HPF_A1*f->lr + HPF_B1*f->lf)>>SCALE_SHIFT; f->lr=v; } return f->lf; }
typedef struct { long min, max, sum; int cnt; char init; } Stat;
void stat_add(Stat* s, long v) { if(!s->init) { s->min=v; s->max=v; s->init=1; } else { if(v<s->min) s->min=v; if(v>s->max) s->max=v; } s->sum+=v; s->cnt++; }
long stat_avg(Stat* s) { return (s->cnt==0)?0:s->sum/s->cnt; }
void stat_rst(Stat* s) { s->min=0; s->max=0; s->sum=0; s->cnt=0; s->init=0; }

LPF lpf_r, lpf_i; HPF hpf1; Stat stat_r, stat_i;
long last_val=0, last_beat=0, f_time=0, last_diff=0, c_time=0;
char f_det=0, crossed=0;

char read_sample(unsigned long *r, unsigned long *i) {
    unsigned char w=max_rd(REG_FIFO_WR_PTR), rd=max_rd(REG_FIFO_RD_PTR), b[6], k;
    if(w==rd) return 0;
    twi_start(); twi_write(MAX30102_ADDR); twi_write(REG_FIFO_DATA); twi_start(); twi_write(MAX30102_ADDR|1);
    for(k=0;k<5;k++) b[k]=twi_read_ack(); b[5]=twi_read_nack(); twi_stop();
    *r=((unsigned long)b[0]<<16|b[1]<<8|b[2])&0x03FFFF; *i=((unsigned long)b[3]<<16|b[4]<<8|b[5])&0x03FFFF;
    return 1;
}

void loop(void) {
    unsigned long raw_r, raw_i;
    long val_r, val_i, ac, diff;
    if(!read_sample(&raw_r, &raw_i)) return;

    val_r = lpf(&lpf_r, (long)raw_r); val_i = lpf(&lpf_i, (long)raw_i);
    ac = hpf(&hpf1, val_r); diff = ac - last_val; last_val = ac;

    if(raw_r > FINGER_THRESHOLD) { if((millis()-f_time)>FINGER_COOLDOWN_MS) f_det=1; }
    else { lpf_r.init=0; lpf_i.init=0; hpf1.init=0; stat_rst(&stat_r); stat_rst(&stat_i); f_det=0; f_time=millis(); current_bpm=0; current_spo2=0; }

    if(f_det) {
        stat_add(&stat_r, val_r); stat_add(&stat_i, val_i);
        if(last_diff>0 && diff<0) { crossed=1; c_time=millis(); }
        if(diff>0) crossed=0;
        if(crossed && diff<EDGE_THRESHOLD) {
            if(last_beat!=0 && (c_time-last_beat)>300) {
                long bpm=60000/(c_time-last_beat);
                long ar=stat_avg(&stat_r), ai=stat_avg(&stat_i);
                if(ar!=0 && ai!=0) {
                    long rat=(stat_r.max-stat_r.min)*100/ar, rat_i=(stat_i.max-stat_i.min)*100/ai;
                    if(rat_i!=0) { current_spo2 = 104 - (17*(rat*100/rat_i))/100; if(current_spo2>100) current_spo2=100; if(current_spo2<80) current_spo2=0; }
                }
                if(bpm>40 && bpm<250) current_bpm=bpm;
                stat_rst(&stat_r); stat_rst(&stat_i);
            }
            crossed=0; last_beat=c_time;
        }
        last_diff=diff;
    }

    print_counter++;
    if(print_counter >= 20) {
        get_time();
        
        // Bluetooth
        bt_str("20"); bt_2digits(rtc_year); bt_transmit('-');
        bt_2digits(rtc_month); bt_transmit('-');
        bt_2digits(rtc_day); bt_transmit(' ');
        bt_2digits(rtc_hour); bt_transmit(':');
        bt_2digits(rtc_min); bt_transmit(':');
        bt_2digits(rtc_sec); bt_transmit(',');
        bt_long((long)raw_r); bt_transmit(',');
        bt_long(current_spo2); bt_transmit(',');
        bt_long(current_bpm); bt_transmit('\r'); bt_transmit('\n');

        // 2. LCD 출력 (깔끔하게 정리)
        // [첫 번째 줄] BPM과 SpO2 표시 (뒤에 공백 2칸씩 추가하여 잔상 제거)
        lcd_gotoxy(0,0); 
        lcd_str("B:"); lcd_long(current_bpm); lcd_str("  "); 
        lcd_str("S:"); lcd_long(current_spo2); lcd_str("%  ");
        
        // [두 번째 줄] 날짜와 시간 표시 (MM-DD HH:MM:SS) -> 딱 14~15글자
        lcd_gotoxy(0,1); 
        if(rtc_month<10) lcd_str("0"); lcd_long(rtc_month); lcd_str("-");
        if(rtc_day<10) lcd_str("0"); lcd_long(rtc_day); lcd_str(" ");
        if(rtc_hour<10) lcd_str("0"); lcd_long(rtc_hour); lcd_str(":");
        if(rtc_min<10) lcd_str("0"); lcd_long(rtc_min); lcd_str(":");
        if(rtc_sec<10) lcd_str("0"); lcd_long(rtc_sec);
        
        print_counter = 0;
    }
}

void DS1302_write(unsigned char r, unsigned char v) {
    DS1302_PORT &= ~(1<<0); // SCLK Low
    DS1302_PORT |= (1<<2);  // RST High
    delay_us(2);
    DS1302_wb(r);           // 주소 전송
    DS1302_wb(v);           // 데이터 전송
    DS1302_PORT &= ~(1<<2); // RST Low
}

void main(void) {
    millis_init();
    bt_init(); // UART0 Init
    
    // [중요] I2C 속도 100kHz로 설정 (TWBR=72 @ 16MHz)
    // 기존 400kHz(TWBR=12)는 LCD 백팩에 너무 빠름
    TWSR=0x00; TWBR=72; TWCR=(1<<TWEN); 
    
    DS1302_init();
    
    /// 1. 쓰기 방지 해제 (Write Protect Off)
    //DS1302_write(0x8E, 0x00); 

    // 2. 시간 설정 (BCD 변환 함수 dec_to_bcd 사용)
    //DS1302_write(0x80, dec_to_bcd(0));  // 초 (00초)
    //DS1302_write(0x82, dec_to_bcd(22)); // 분 (20분)
    //DS1302_write(0x84, dec_to_bcd(23)); // 시 (23시 = 오후 11시)
    //DS1302_write(0x86, dec_to_bcd(8));  // 일 (8일)
    //DS1302_write(0x88, dec_to_bcd(12)); // 월 (12월)
    //DS1302_write(0x8C, dec_to_bcd(25)); // 년 (2025년 -> 25)

    // 3. 쓰기 방지 설정 (Write Protect On)
    //DS1302_write(0x8E, 0x80);
    // ============================================

    lcd_init(); 
    lcd_gotoxy(0,0); lcd_str("Init...");
    
    // max30102 setup
    max_wr(0x09, 0x40); delay_ms(100); max_wr(0x08, 0x50); max_wr(0x09, 0x03); max_wr(0x0A, 0x2F); 
    max_wr(0x0C, 0x1F); max_wr(0x0D, 0x1F); max_wr(0x04, 0x00); max_wr(0x05, 0x00); max_wr(0x06, 0x00);
    delay_ms(1000); lcd_cmd(0x01);

    while (1) { loop(); }
}