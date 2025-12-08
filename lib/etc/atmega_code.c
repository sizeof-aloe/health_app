/*
 * MAX30102 Heart Rate Monitor
 * Features: 
 * 1. Bandpass Filter (1Hz ~ 3Hz)
 * 2. 2nd Derivative Logic (Sharpen Peaks)
 * 3. Refractory Period (200ms)
 * 4. BPM Moving Average
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

// Registers
#define REG_FIFO_WR_PTR 0x04
#define REG_FIFO_RD_PTR 0x06
#define REG_FIFO_DATA 0x07 
#define REG_MODE_CONFIG 0x09
#define REG_SPO2_CONFIG 0x0A

// LCD Control
#define LCD_EN 0x04  
#define LCD_RW 0x02  
#define LCD_RS 0x01  
#define LCD_BL 0x08  

// --- Filter & Logic Constants ---
#define SCALE_SHIFT 10 

// 1. LPF (Cutoff ~ 3Hz @ 100Hz SR)
#define LPF_A0 174   
#define LPF_B1 850  

// 2. HPF (Cutoff ~ 1Hz @ 100Hz SR)
#define HPF_A0 962 
#define HPF_A1 962
#define HPF_B1 962

// 3. Beat Detection
#define FINGER_THRESHOLD 30000 
#define FINGER_COOLDOWN_MS 300
// 미분 필터를 거치면 값이 커지므로 임계값도 상황에 따라 조정 가능하지만, 
// 하강 엣지 감지이므로 음수 값 유지 (더 민감하게 반응함)
#define EDGE_THRESHOLD -10      
#define REFRACTORY_PERIOD 200   
#define BPM_BUF_SIZE 5          

// --- 전역 변수 ---
char g_buf[20]; 

volatile unsigned long timer0_millis = 0;
int print_counter = 0;
long current_bpm = 0, current_spo2 = 0;
unsigned char rtc_hour = 0, rtc_min = 0, rtc_sec = 0;
unsigned char rtc_year = 0, rtc_month = 0, rtc_day = 0;

int bpm_buf[BPM_BUF_SIZE];
unsigned char bpm_idx = 0;
unsigned char bpm_cnt = 0;

// ==========================================
// Utils & Drivers
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

interrupt [TIM0_COMP] void timer0_comp_isr(void) { timer0_millis++; }
void millis_init(void) { TCCR0 = (1 << WGM01) | (1 << CS02); OCR0 = 249; TIMSK |= (1 << OCIE0); #asm("sei") }
unsigned long millis(void) { unsigned long m; #asm("cli") m = timer0_millis; #asm("sei") return m; }

void bt_init(void) { 
    UBRR0H = 0; UBRR0L = MYUBRR; 
    UCSR0B = (1 << RXEN0) | (1 << TXEN0); 
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00); 
}
void bt_transmit(char data) { while (!(UCSR0A & (1 << UDRE0))); UDR0 = data; }
void bt_str(char* str) { while (*str) bt_transmit(*str++); }
void bt_long(long val) { long_to_str(val); bt_str(g_buf); } 
void bt_2digits(unsigned char val) { if (val < 10) bt_transmit('0'); bt_long((long)val); }

void twi_start(void) { TWCR=(1<<TWINT)|(1<<TWSTA)|(1<<TWEN); while(!(TWCR&(1<<TWINT))); }
void twi_stop(void) { TWCR=(1<<TWINT)|(1<<TWSTO)|(1<<TWEN); }
void twi_write(unsigned char d) { TWDR=d; TWCR=(1<<TWINT)|(1<<TWEN); while(!(TWCR&(1<<TWINT))); }
unsigned char twi_read_ack(void) { TWCR=(1<<TWINT)|(1<<TWEN)|(1<<TWEA); while(!(TWCR&(1<<TWINT))); return TWDR; }
unsigned char twi_read_nack(void) { TWCR=(1<<TWINT)|(1<<TWEN); while(!(TWCR&(1<<TWINT))); return TWDR; }

// DS1302
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

// LCD
void lcd_i2c(unsigned char *b, unsigned char l) { 
    unsigned char i; twi_start(); twi_write(LCD_I2C_ADDR); 
    for(i=0;i<l;i++) twi_write(b[i]); twi_stop(); 
}
void lcd_half_cmd(unsigned char c) {
    unsigned char b[2]; b[0] = (c & 0xF0) | LCD_EN | LCD_BL; b[1] = (c & 0xF0) | LCD_BL; lcd_i2c(b, 2);
}
void lcd_cmd(unsigned char c) {
    unsigned char b[4];
    b[0] = (c & 0xF0) | LCD_EN | LCD_BL; b[1] = (c & 0xF0) | LCD_BL;
    b[2] = ((c << 4) & 0xF0) | LCD_EN | LCD_BL; b[3] = ((c << 4) & 0xF0) | LCD_BL;
    lcd_i2c(b, 4);
}
void lcd_data(unsigned char d) {
    unsigned char b[4];
    b[0] = (d & 0xF0) | LCD_EN | LCD_RS | LCD_BL; b[1] = (d & 0xF0) | LCD_RS | LCD_BL;
    b[2] = ((d << 4) & 0xF0) | LCD_EN | LCD_RS | LCD_BL; b[3] = ((d << 4) & 0xF0) | LCD_RS | LCD_BL;
    lcd_i2c(b, 4);
}
void lcd_gotoxy(unsigned char x, unsigned char y) { lcd_cmd(0x80|((0x40*y)+x)); }
void lcd_str(char *s) { while(*s) lcd_data(*s++); }
void lcd_long(long v) { long_to_str(v); lcd_str(g_buf); }

void lcd_init(void) {
    delay_ms(50); lcd_half_cmd(0x30); delay_ms(5); lcd_half_cmd(0x30); delay_ms(1); 
    lcd_half_cmd(0x30); delay_ms(1); lcd_half_cmd(0x20); delay_ms(1); 
    lcd_cmd(0x28); lcd_cmd(0x0C); lcd_cmd(0x06); lcd_cmd(0x01); delay_ms(2);   
}

// MAX30102
void max_wr(unsigned char r, unsigned char v) { twi_start(); twi_write(MAX30102_ADDR); twi_write(r); twi_write(v); twi_stop(); }
unsigned char max_rd(unsigned char r) {
    unsigned char v; twi_start(); twi_write(MAX30102_ADDR); twi_write(r);
    twi_start(); twi_write(MAX30102_ADDR|1); v=twi_read_nack(); twi_stop(); return v;
}

// ==========================================
// [Filter Logic]
// ==========================================

// 1. LPF Structure
typedef struct { long last; char init; } LPF;
long lpf_3hz(LPF* f, long v) { 
    if(!f->init) { f->last=v; f->init=1; } 
    else f->last = (LPF_A0*v + LPF_B1*f->last) >> SCALE_SHIFT; 
    return f->last; 
}

// 2. HPF Structure
typedef struct { long lf, lr; char init; } HPF;
long hpf_1hz(HPF* f, long v) { 
    if(!f->init) { f->lf=0; f->lr=v; f->init=1; } 
    else { 
        f->lf = (HPF_A0*v - HPF_A1*f->lr + HPF_B1*f->lf) >> SCALE_SHIFT; 
        f->lr = v; 
    } 
    return f->lf; 
}

// 3. [NEW] 2nd Derivative Structure (가중치 기울기)
// Logic: Y[n] = 13*S[n] + 11*S[n-1], where S = Diff
typedef struct { 
    long prev_x; 
    long prev_s; 
    char init; 
} Deriv;

long process_2nd_derivative(Deriv* d, long x) {
    long s, y;
    if (!d->init) {
        d->prev_x = x;
        d->prev_s = 0;
        d->init = 1;
        return 0;
    }
    s = x - d->prev_x;            // 현재 기울기
    y = 13 * s + 11 * d->prev_s;  // 가중치 적용
    d->prev_x = x;                // 값 갱신
    d->prev_s = s;
    return y;
}

// Stats for SpO2
typedef struct { long min, max, sum; int cnt; char init; } Stat;
void stat_add(Stat* s, long v) { if(!s->init) { s->min=v; s->max=v; s->init=1; } else { if(v<s->min) s->min=v; if(v>s->max) s->max=v; } s->sum+=v; s->cnt++; }
long stat_avg(Stat* s) { return (s->cnt==0)?0:s->sum/s->cnt; }
void stat_rst(Stat* s) { s->min=0; s->max=0; s->sum=0; s->cnt=0; s->init=0; }

// --- Global Logic Variables ---
LPF lpf_r, lpf_i; 
HPF hpf_r, hpf_i; 
Deriv deriv_r; // 2차 미분용 구조체 선언
Stat stat_r, stat_i;

long last_beat=0, f_time=0, last_deriv=0, c_time=0;
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
    long val_r, val_i, ac_r, ac_i;
    
    // [선언부] 블록 최상단 배치
    long deriv_out; // 2차 미분 결과값
    long bpm, ar, ai, rat, rat_i, bpm_sum; 
    unsigned char k;

    if(!read_sample(&raw_r, &raw_i)) return;

    // 1. [LPF 3Hz]
    val_r = lpf_3hz(&lpf_r, (long)raw_r); 
    val_i = lpf_3hz(&lpf_i, (long)raw_i);
    
    // 2. [HPF 1Hz] -> AC Signal
    ac_r = hpf_1hz(&hpf_r, val_r);
    ac_i = hpf_1hz(&hpf_i, val_i);

    // 3. [2nd Derivative] 피크 강화 필터 적용
    // ac_r 신호를 입력으로 받아 날카로운 엣지 신호 생성
    deriv_out = process_2nd_derivative(&deriv_r, ac_r);
    
    if(raw_r > FINGER_THRESHOLD) { 
        if((millis()-f_time)>FINGER_COOLDOWN_MS) f_det=1; 
    }
    else { 
        // [RESET] 손가락 뗐을 때 모든 필터 초기화
        lpf_r.init=0; lpf_i.init=0; 
        hpf_r.init=0; hpf_i.init=0;
        deriv_r.init=0; // 미분 필터 초기화 필수
        
        stat_rst(&stat_r); stat_rst(&stat_i); 
        f_det=0; f_time=millis(); 
        current_bpm=0; current_spo2=0;
        bpm_idx = 0; bpm_cnt = 0; 
    }

    if(f_det) {
        stat_add(&stat_r, ac_r); // SpO2 계산용 (진폭)
        stat_add(&stat_i, ac_i);
        
        // [Detection Logic]
        // 이제 'deriv_out' (2차 미분값)을 사용하여 Zero Crossing 감지
        // 신호가 급격히 하강할 때(Peak 직후) deriv_out은 큰 음수 값을 가짐
        
        // 1. Zero Crossing Check (Falling Slope)
        if(last_deriv > 0 && deriv_out < 0) { 
            // 2. Refractory Period Check (200ms)
            if((millis() - last_beat) > REFRACTORY_PERIOD) {
                crossed = 1; 
                c_time = millis(); 
            }
        }
        
        if(deriv_out > 0) crossed = 0;

        // 3. Threshold Check
        if(crossed && deriv_out < EDGE_THRESHOLD) {
            if(last_beat != 0) {
                 bpm = 60000 / (c_time - last_beat);
                 
                 // SpO2 Calculation
                 ar = stat_avg(&stat_r); ai = stat_avg(&stat_i);
                 if(ar != 0 && ai != 0) {
                     rat = (stat_r.max - stat_r.min) * 1000 / 100; 
                     rat_i = (stat_i.max - stat_i.min) * 1000 / 100;
                     if(rat_i != 0) { 
                         current_spo2 = 104 - (17 * (rat * 100 / rat_i)) / 100; 
                         if(current_spo2 > 100) current_spo2 = 100; 
                         if(current_spo2 < 80) current_spo2 = 0; 
                     }
                 }

                 // BPM Moving Average
                 if(bpm > 40 && bpm < 250) {
                     bpm_buf[bpm_idx++] = (int)bpm;
                     if(bpm_idx >= BPM_BUF_SIZE) bpm_idx = 0; 
                     if(bpm_cnt < BPM_BUF_SIZE) bpm_cnt++;

                     bpm_sum = 0;
                     for(k = 0; k < bpm_cnt; k++) bpm_sum += bpm_buf[k];
                     current_bpm = bpm_sum / bpm_cnt; 
                 }
                 stat_rst(&stat_r); stat_rst(&stat_i);
            }
            crossed = 0; 
            last_beat = c_time; 
        }
        last_deriv = deriv_out; // 다음 비교를 위해 현재 값 저장
    }

    print_counter++;
    // SR=100Hz 이므로 5번마다 전송해야 초당 20회 전송됨
    if(print_counter >= 5) { 
        get_time();
        
        // Bluetooth Output
        bt_str("20"); bt_2digits(rtc_year); bt_transmit('-');
        bt_2digits(rtc_month); bt_transmit('-');
        bt_2digits(rtc_day); bt_transmit(' ');
        bt_2digits(rtc_hour); bt_transmit(':');
        bt_2digits(rtc_min); bt_transmit(':');
        bt_2digits(rtc_sec); bt_transmit(',');
        
        // [중요] 그래프 확인을 위해 미분된 파형(deriv_out)을 전송
        // 이 값이 0을 기준으로 위아래로 뾰족하게 튀는지 확인하세요.
        bt_long(deriv_out); bt_transmit(','); 
        
        bt_long(current_spo2); bt_transmit(',');
        bt_long(current_bpm); bt_transmit('\r'); bt_transmit('\n');

        // LCD Output
        lcd_gotoxy(0,0); lcd_str("B:"); lcd_long(current_bpm); lcd_str("  "); 
        lcd_str("S:"); lcd_long(current_spo2); lcd_str("%  ");
        lcd_gotoxy(0,1); 
        if(rtc_hour<10) lcd_str("0"); lcd_long(rtc_hour); lcd_str(":");
        if(rtc_min<10) lcd_str("0"); lcd_long(rtc_min); lcd_str(":");
        if(rtc_sec<10) lcd_str("0"); lcd_long(rtc_sec); lcd_str("    ");
        
        print_counter = 0;
    }
}

void main(void) {
    millis_init();
    bt_init(); 
    TWSR=0x00; TWBR=72; TWCR=(1<<TWEN); 
    DS1302_init();
    lcd_init(); 
    lcd_gotoxy(0,0); lcd_str("Filter: 2nd Deriv");
    
    // MAX30102 Config (SR = 100Hz for Filters)
    max_wr(0x09, 0x40); delay_ms(100); 
    max_wr(0x08, 0x50); 
    max_wr(0x09, 0x03); 
    max_wr(0x0A, 0x27); // SR = 100Hz
    max_wr(0x0C, 0x1F); max_wr(0x0D, 0x1F); 
    max_wr(0x04, 0x00); max_wr(0x05, 0x00); max_wr(0x06, 0x00);
    
    delay_ms(1000); lcd_cmd(0x01);
    while (1) { loop(); }
}