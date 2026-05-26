// Product detail — plain UI. No tracking code.
import React from 'react';
import {Text, StyleSheet, View} from 'react-native';
import {Btn, Screen} from './ui';

export default function ProductDetailScreen({route, navigation}: any) {
  const product = route.params?.product ?? {name: 'Sản phẩm', price: 0};
  return (
    <Screen>
      <View style={styles.hero}>
        <Text style={styles.heroText}>{product.name[0]}</Text>
      </View>
      <Text style={styles.title}>{product.name}</Text>
      <Text style={styles.price}>{product.price.toLocaleString('vi-VN')}đ</Text>
      <Btn testID="detail_add_to_cart" title="Thêm vào giỏ" onPress={() => {}} />
      <Btn testID="detail_buy_now" title="Mua ngay"
        onPress={() => navigation.navigate('Network')} />
    </Screen>
  );
}

const styles = StyleSheet.create({
  hero: {height: 160, borderRadius: 16, backgroundColor: '#DCE6FF',
    alignItems: 'center', justifyContent: 'center'},
  heroText: {fontSize: 64},
  title: {fontSize: 22, fontWeight: 'bold'},
  price: {fontSize: 18, color: '#5B8CFF'},
});
